#!/usr/bin/env bash
# Usage:
#   pr-comment.sh post  <key> <body-file>
#   pr-comment.sh check <key> <title> <job-status> [details-file]
# One comment per key is kept on the PR and updated in place.
# `check` posts the details on failure and marks an existing comment as passed on success.
# Details ending in .log are shown as the last lines of the log, anything else as Markdown.
set -euo pipefail

PR=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
HEAD_SHA=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
MAX_CHARS=60000

upsert() {
  local key="$1" body="$2" update_only="${3:-false}"
  local marker="<!-- pr-comment:$key -->"
  body="$marker"$'\n'"$body"
  local id
  id=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR/comments" \
    --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)
  if [[ -n "$id" ]]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -f body="$body" > /dev/null
  elif [[ "$update_only" != true ]]; then
    gh pr comment "$PR" --body "$body" > /dev/null
  fi
}

details() {
  local file="$1"
  [[ -s "$file" ]] || return 0
  if [[ "$file" == *.log ]]; then
    printf '```text\n%s\n```\n' "$(tail -n 60 "$file" | sed 's/\x1b\[[0-9;]*m//g')"
  else
    head -c "$MAX_CHARS" "$file"
  fi
}

case "$1" in
  post)
    upsert "$2" "$(head -c "$MAX_CHARS" "$3")"
    ;;
  check)
    key="$2" title="$3" status="$4" file="${5:-}"
    case "$status" in
      failure)
        upsert "$key" "### :x: $title failed

$(details "$file")

Commit \`${HEAD_SHA::7}\`, [run log]($RUN_URL)."
        ;;
      success)
        upsert "$key" "### :white_check_mark: $title passed

Commit \`${HEAD_SHA::7}\`, [run log]($RUN_URL)." true
        ;;
    esac
    ;;
  *)
    echo "unknown command: $1" >&2
    exit 1
    ;;
esac
