#!/usr/bin/env bash
# Usage: trivy-report.sh <trivy.json>
# Prints the findings of a Trivy JSON report as Markdown tables (nothing if there are none).
set -euo pipefail

jq -r '
  def cell: tostring | gsub("\\|"; "/") | gsub("\n"; " ");
  def link: if .PrimaryURL then "[\(.id)](\(.PrimaryURL))" else .id end;

  [.Results[]? | .Target as $t | .Vulnerabilities[]? | . + {id: .VulnerabilityID, target: $t}] as $vulns
  | [.Results[]? | .Target as $t | .Misconfigurations[]? | . + {id: .ID, target: $t}] as $misconfs
  | (if ($vulns | length) > 0 then
      "**Vulnerabilities: \($vulns | length)**\n",
      "| Severity | ID | Package | Installed | Fixed | Title |",
      "|---|---|---|---|---|---|",
      ($vulns[] | "| \(.Severity) | \(link) | `\(.PkgName)` | \(.InstalledVersion) | \(.FixedVersion // "-") | \(.Title // "" | cell) |"),
      ""
    else empty end),
    (if ($misconfs | length) > 0 then
      "**Misconfigurations: \($misconfs | length)**\n",
      "| Severity | ID | Location | Problem |",
      "|---|---|---|---|",
      ($misconfs[] | "| \(.Severity) | \(link) | `\(.target):\(.CauseMetadata.StartLine // "-")` | \(.Title | cell) \(.Message | cell) |"),
      ""
    else empty end)
' "$1"
