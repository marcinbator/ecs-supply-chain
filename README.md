# ecs-supply-chain

A secure supply chain for a containerized application on AWS. The FastAPI app is built, scanned (Trivy), described with an SBOM, signed (Cosign keyless) and deployed by digest to ECS Fargate with blue/green, a 5 minute bake time and rollback on CloudWatch alarms. Terraform changes go through a PR with a Trivy scan and a cost estimate that requires approval above a threshold.

Docs: [architecture](docs/architecture.md), [presentation runbook](docs/presentation.md).

## Structure

```text
app/                  application, tests, Dockerfile, VERSION
terraform/            infrastructure (single root module, S3 backend)
.github/workflows/    app.yml (application), infra.yml (infrastructure)
scripts/              deploy.sh, cost.py, loadgen.sh, demo-unsigned.sh
docs/                 architecture, presentation runbook
```

## Setup

Requirements: AWS CLI v2, Terraform >= 1.10, Docker, `jq`, `cosign`, public GitHub repository.

1. **S3 state bucket** (AWS console): region `eu-central-1`, account regional namespace, name `ecs-supply-chain-state` (full name as in `terraform/backend.tf`), Block all public access, Versioning enabled, SSE-S3.
2. **OIDC provider** (IAM, Identity providers, skip if it exists): OpenID Connect, URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
3. **Terraform**: copy `terraform/terraform.tfvars.example` to `terraform.tfvars`, set `github_oidc_repo`, then `terraform init && terraform apply`. The value has the format `owner@<owner-id>/repo@<repo-id>`, because GitHub puts immutable IDs into the OIDC `sub` claim for repositories created after 2026-07-15:

   ```bash
   curl -s https://api.github.com/repos/<owner>/<repo> | jq '.owner.id, .id'
   ```

4. **GitHub repository variables**: `AWS_ACCOUNT_ID`, `AWS_REGION` (`eu-central-1`), `COST_THRESHOLD_USD` (`10`). No secrets.
5. **GitHub environments**:
   - `infra`: deployment branches limited to `main`. Only `terraform apply` runs here and only this environment can assume `gh-infra-apply`.
   - `infra-cost-approval`: required reviewers, "Prevent self-review" unchecked. `cost-gate` waits here when the cost increase is above the threshold.
6. **Ruleset for `main`**: require a PR, require status checks `trivy` and `cost-gate`, block force pushes.
7. **First deployment**: Actions, **app**, **Run workflow** (`failure_mode = none`). The service starts with 0 tasks and a placeholder image until then. Takes about 7-10 minutes.

## Alarms and bake time

Alarms on ALB `HTTPCode_Target_5XX_Count` and `TargetResponseTime` use a 60 s period and 2 of 3 datapoints, so they fire about 3 minutes after errors start. In the `delayed` scenario errors start 90 s after container start, about half a minute after the traffic shift, so the alarm fires about 3-3.5 minutes into the 5 minute bake time and ECS rolls back to the old version.

## FinOps

[scripts/cost.py](scripts/cost.py) prices the Terraform plan in the `plan` job with fixed `eu-central-1` on-demand prices from the AWS Price List API (no external service), comments the result on the PR and feeds `cost-gate`. Usage-based costs are not included.

The running environment costs about 0.065 USD/h (about 47 USD/month): ALB, one Fargate task and public IPv4 addresses.

## Cleanup

`cd terraform && terraform destroy`. The state bucket and the OIDC provider stay and cost nothing, delete them in the console if no longer needed.
