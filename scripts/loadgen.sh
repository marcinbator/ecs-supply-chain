#!/usr/bin/env bash
# Usage: loadgen.sh [alb-url] [duration-seconds]
# Sends about 5 requests per second to /version, writes time, HTTP code and
# version to a CSV file and prints a summary at the end (or on Ctrl+C).
set -uo pipefail

URL="${1:-$(terraform -chdir="$(dirname "$0")/../terraform" output -raw alb_url)}"
DURATION="${2:-0}"
CSV="loadgen-$(date +%Y%m%d-%H%M%S).csv"

echo "time,code,version" > "$CSV"

summarize() {
  awk -F, 'NR > 1 {
      total++
      if ($2 != "200") {
        errors++
        if (!in_error) { start = $1; in_error = 1 }
        last_error = $1
      } else if (in_error) {
        ranges = ranges sprintf("  %s - %s\n", start, last_error); in_error = 0
      }
      if ($3 != "" && $3 != prev) {
        changes = changes sprintf("  %s: %s -> %s\n", $1, (prev == "" ? "start" : prev), $3); prev = $3
      }
    }
    END {
      if (in_error) ranges = ranges sprintf("  %s - %s\n", start, last_error)
      printf "requests: %d\nerrors: %d\nerror periods:\n%sversion changes:\n%s", total, errors, ranges, changes
    }' "$CSV"
  echo "data: $CSV"
  exit 0
}
trap summarize INT TERM

END=$(( $(date +%s) + DURATION ))
while [[ "$DURATION" -eq 0 || $(date +%s) -lt $END ]]; do
  BODY=$(curl -s --max-time 2 -w '\n%{http_code}' "$URL/version")
  CODE=$(tail -n1 <<< "$BODY")
  VERSION=$(head -n -1 <<< "$BODY" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  echo "$(date +%T.%3N),$CODE,$VERSION" | tee -a "$CSV"
  sleep 0.2
done
summarize
