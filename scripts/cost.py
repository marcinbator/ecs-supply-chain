"""Estimate the monthly cost change of a Terraform plan.

Usage: cost.py <plan.json>
Prints a Markdown report. In GitHub Actions also writes `diff` and
`over_threshold` (threshold from COST_THRESHOLD_USD, default 10) to GITHUB_OUTPUT.
"""

import json
import os
import sys

HOURS_PER_MONTH = 730

# On-demand eu-central-1 prices in USD from the AWS Price List API (2026-10)
ALB_HOUR = 0.027
NAT_GATEWAY_HOUR = 0.052
PUBLIC_IPV4_HOUR = 0.005
VPC_ENDPOINT_HOUR = 0.012
FARGATE_VCPU_HOUR = 0.04656
FARGATE_GB_HOUR = 0.00511
ALARM_MONTH = 0.10


def monthly_cost(resource_type, values):
    if values is None:
        return 0.0
    if resource_type == "aws_lb":
        # internet-facing load balancer in two AZs holds two public IPv4 addresses
        return (ALB_HOUR + 2 * PUBLIC_IPV4_HOUR) * HOURS_PER_MONTH
    if resource_type == "aws_nat_gateway":
        return NAT_GATEWAY_HOUR * HOURS_PER_MONTH
    if resource_type == "aws_eip":
        return PUBLIC_IPV4_HOUR * HOURS_PER_MONTH
    if resource_type == "aws_vpc_endpoint" and values.get("vpc_endpoint_type") == "Interface":
        return VPC_ENDPOINT_HOUR * HOURS_PER_MONTH * max(len(values.get("subnet_ids") or []), 1)
    if resource_type == "aws_ecs_task_definition":
        # assumes one running Fargate task with a public IPv4 per task definition
        vcpu = int(values.get("cpu") or 0) / 1024
        gb = int(values.get("memory") or 0) / 1024
        return (vcpu * FARGATE_VCPU_HOUR + gb * FARGATE_GB_HOUR + PUBLIC_IPV4_HOUR) * HOURS_PER_MONTH
    if resource_type == "aws_cloudwatch_metric_alarm":
        return ALARM_MONTH
    return 0.0


def main(plan_path):
    with open(plan_path) as f:
        plan = json.load(f)

    threshold = float(os.getenv("COST_THRESHOLD_USD") or 10)
    before_total = after_total = 0.0
    rows = []
    for change in plan.get("resource_changes", []):
        if change["mode"] != "managed":
            continue
        before = monthly_cost(change["type"], change["change"]["before"])
        after = monthly_cost(change["type"], change["change"]["after"])
        before_total += before
        after_total += after
        if round(after - before, 2):
            rows.append(f"| `{change['address']}` | {', '.join(change['change']['actions'])} | {after - before:+.2f} |")

    diff = after_total - before_total
    over = diff > threshold

    print("## Cost estimate (eu-central-1, USD/month)\n")
    print(f"- before: **{before_total:.2f}**")
    print(f"- after: **{after_total:.2f}**")
    print(f"- diff: **{diff:+.2f}** (threshold {threshold:.2f})")
    print(f"- approval required: **{'yes' if over else 'no'}**\n")
    if rows:
        print("| Resource | Action | Diff |\n|---|---|---|")
        print("\n".join(rows))
    print("\nFixed hourly costs only (ALB, NAT Gateway, public IPv4, interface endpoints, Fargate, alarms).")

    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"diff={diff:.2f}\nover_threshold={'true' if over else 'false'}\n")


if __name__ == "__main__":
    main(sys.argv[1])
