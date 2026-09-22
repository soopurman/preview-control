#!/usr/bin/env bash
# Wait for a stack terminal state, then verify the public FastAPI surface a reviewer will use.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/check_environment.sh STACK_NAME [--region REGION] [--timeout SECONDS]

The check waits for CREATE_COMPLETE or UPDATE_COMPLETE, then verifies /a and /b health
and their non-empty seeded /items collections. It prints the ALB URL and Swagger URLs.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
stack_name="$1"
shift
region="${AWS_REGION:-us-east-2}"
timeout_seconds=1800
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) region="${2:?missing region}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?missing timeout}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "AWS CLI is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
export AWS_REGION="$region"

started_at=$(date +%s)
while true; do
  status=$(aws cloudformation describe-stacks --stack-name "$stack_name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE) break ;;
    *FAILED|*ROLLBACK*|DELETE_COMPLETE)
      echo "$stack_name finished unsuccessfully: $status" >&2
      aws cloudformation describe-stack-events --stack-name "$stack_name" --max-items 10 --output table >&2 || true
      exit 1
      ;;
    ""|None) echo "Waiting for CloudFormation stack $stack_name to appear..." ;;
    *) echo "Waiting for $stack_name: $status" ;;
  esac
  if (( $(date +%s) - started_at >= timeout_seconds )); then
    echo "Timed out after ${timeout_seconds}s waiting for $stack_name." >&2
    exit 1
  fi
  sleep 15
done

preview_url=$(aws cloudformation describe-stacks --stack-name "$stack_name" \
  --query "Stacks[0].Outputs[?OutputKey=='PreviewUrl'].OutputValue" --output text)
[[ -n "$preview_url" && "$preview_url" != "None" ]] || { echo "PreviewUrl output is missing." >&2; exit 1; }

curl --fail --silent --show-error --retry 30 --retry-all-errors --retry-delay 5 "$preview_url/a/health" | jq .
curl --fail --silent --show-error --retry 30 --retry-all-errors --retry-delay 5 "$preview_url/b/health" | jq .
curl --fail --silent --show-error "$preview_url/a/items" | jq --exit-status 'type == "array" and length > 0' >/dev/null
curl --fail --silent --show-error "$preview_url/b/items" | jq --exit-status 'type == "array" and length > 0' >/dev/null

echo "Environment is ready: $preview_url"
echo "  Catalog docs: $preview_url/a/docs"
echo "  Orders docs:  $preview_url/b/docs"
