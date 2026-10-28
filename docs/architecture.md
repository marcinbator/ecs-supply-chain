# Architecture

## AWS infrastructure

```mermaid
flowchart LR
  user([User / loadgen]) -->|HTTP 80| alb[ALB]
  subgraph vpc[VPC, 2 public subnets in 2 AZs]
    alb -->|production rule| tgb[Target group blue]
    alb -->|test rule X-Deployment-Test| tgg[Target group green]
    tgb --> t1[Fargate tasks, current version]
    tgg --> t2[Fargate tasks, new version]
  end
  t1 & t2 -->|HTTPS 443, public IP| ecr[(ECR, IMMUTABLE, scan on push)]
  t1 & t2 --> logs[(CloudWatch Logs)]
  alb -. metrics .-> cw[CloudWatch alarms: 5xx, response time]
  cw -. rollback .-> ecs[ECS service, BLUE_GREEN, bake 5 min]
  ecs --> t1 & t2
  gh[GitHub Actions] -->|OIDC| iam[Roles gh-plan, gh-infra-apply, gh-app-deploy]
  iam --> ecr & ecs
  tf[(S3: Terraform state)] --- gh
```

Resources:

- `network.tf`: VPC, 2 public subnets, Internet Gateway, no NAT Gateway,
- `ecr.tf`: repository with immutable tags, scan on push, KMS encryption, lifecycle (20 images),
- `alb.tf`: ALB, HTTP 80 listener, blue and green target groups with a `/health` health check, production and test rules,
- `ecs.tf`: cluster with Container Insights, task definition (read-only root filesystem), service with the `BLUE_GREEN` strategy,
- `monitoring.tf`: ALB-level alarms (`LoadBalancer` dimension, covers both target groups),
- `iam.tf`: GitHub Actions roles, task execution role, ECS infrastructure role for blue/green.

## Application pipeline (`app.yml`)

```mermaid
flowchart TB
  subgraph ci [Every run: push, PR, manual]
    direction LR
    B[pytest] --> C[docker build] --> D{Trivy: CRITICAL?}
    D -->|yes| X[stop, nothing pushed to ECR]
    D -->|no| E[SBOM CycloneDX] --> F{PR?}
    F -->|yes| Y[stop, no deployment]
  end
  subgraph cd [main only]
    direction LR
    G[OIDC, push to ECR, digest] --> H[cosign sign, attest SBOM] --> I{cosign verify}
    I -->|no signature| Z[stop, service unchanged]
    I -->|OK| J[task definition with repo@sha256] --> K[update-service] --> L[report]
  end
  ci -->|no| cd
```

Signature verification and deployment live in `scripts/deploy.sh`. The same script is called by `scripts/demo-unsigned.sh`, so the unsigned image demo uses exactly the same path as the pipeline.

## Infrastructure pipeline (`infra.yml`)

```mermaid
flowchart LR
  P[PR] --> plan[terraform plan<br>role gh-plan] --> cost[cost.py<br>PR comment] --> gate{cost increase<br>> threshold?}
  gate -->|yes| ap[cost-gate<br>infra-cost-approval<br>waits for reviewer]
  gate -->|no| ok[cost-gate<br>infra-cost-ok]
  P --> trivy[trivy config]
  ap & ok & trivy --> merge[merge to main] --> apply[terraform apply<br>environment infra<br>role gh-infra-apply]
```

## Blue/green deployment with bake time

```mermaid
sequenceDiagram
  participant P as Pipeline
  participant E as ECS
  participant A as ALB
  participant C as CloudWatch
  P->>E: update-service (new revision, digest)
  E->>E: start green tasks
  E->>A: register in green target group, health check /health
  alt health check fails
    E->>E: circuit breaker, deployment stopped
    Note over A: production traffic stays on blue
  else health check OK
    E->>A: test traffic to green, then production traffic to green
    Note over E: bake time 5 min, blue still running
    alt 5xx or response time alarm
      C-->>E: ALARM
      E->>A: traffic back to blue
      E->>E: stop green (rollback)
    else no alarm for 5 min
      E->>E: stop blue, green becomes production
    end
  end
  P->>E: describe-service-deployments, report
```
