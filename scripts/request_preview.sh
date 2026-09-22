#!/usr/bin/env bash
# Dispatch the same coordinator workflow that service branch events invoke, then wait and smoke test it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/request_preview.sh --service a|b --ref BRANCH [options]

Examples:
  bash scripts/request_preview.sh --service a --ref main
  bash scripts/request_preview.sh --service a --ref fg/demo

Options:
  --control-repo OWNER/REPO  Coordinator repository (default: this repository's origin)
  --region REGION            AWS region (default: us-east-2)
  --no-wait                  Trigger only; do not wait for workflow or test the API
  -h, --help                 Show this help
EOF
}

service=""
ref=""
control_repo=""
region="us-east-2"
wait_for_result=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) service="${2:?missing service}"; shift 2 ;;
    --ref) ref="${2:?missing ref}"; shift 2 ;;
    --control-repo) control_repo="${2:?missing control repository}"; shift 2 ;;
    --region) region="${2:?missing region}"; shift 2 ;;
    --no-wait) wait_for_result=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$service" == a || "$service" == b ]] || { echo "--service must be a or b." >&2; exit 2; }
[[ -n "$ref" ]] || { echo "--ref is required." >&2; exit 2; }

command -v gh >/dev/null || { echo "GitHub CLI (gh) is required." >&2; exit 1; }
gh auth status >/dev/null
if [[ -z "$control_repo" ]]; then
  control_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

# This is only for selecting the final smoke-check stack; resolve_preview.py still decides refs.
if [[ "$ref" == main ]]; then
  stack_name="BaselineEnvironment"
else
  if [[ "$ref" == fg/* ]]; then preview_id="fg-${ref#fg/}"; else preview_id="${service}-${ref}"; fi
  preview_id=$(printf '%s' "$preview_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g; s/^(.{32}).*/\1/; s/-+$//')
  [[ -n "$preview_id" ]] || { echo "Branch name cannot form a preview ID." >&2; exit 2; }
  stack_name="Preview-$preview_id"
fi

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run preview.yml --repo "$control_repo" --ref main \
  -f service="$service" -f ref="$ref" -f lifecycle=upsert
echo "Workflow dispatched for $service:$ref."
[[ "$wait_for_result" == true ]] || exit 0

run_id=""
for _ in $(seq 1 24); do
  run_id=$(gh run list --repo "$control_repo" --workflow preview.yml --event workflow_dispatch --limit 20 \
    --json databaseId,createdAt | jq -r --arg started_at "$started_at" \
    '[.[] | select(.createdAt >= $started_at) | .databaseId] | first // empty')
  [[ -n "$run_id" ]] && break
  sleep 5
done
[[ -n "$run_id" ]] || { echo "Workflow dispatch was accepted but its run was not found." >&2; exit 1; }
echo "Waiting for GitHub Actions run $run_id..."
gh run watch "$run_id" --repo "$control_repo" --exit-status

project_root=$(cd "$(dirname "$0")/.." && pwd)
bash "$project_root/scripts/check_environment.sh" "$stack_name" --region "$region"
