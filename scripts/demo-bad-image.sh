#!/usr/bin/env bash
# Usage: demo-bad-image.sh [health|delayed]
set -euo pipefail

MODE="${1:-delayed}"
gh workflow run app.yml --ref main -f failure_mode="$MODE"
sleep 5
RUN_ID=$(gh run list --workflow app.yml --event workflow_dispatch --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN_ID"
