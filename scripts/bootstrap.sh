#!/usr/bin/env bash
# One command for a fresh AWS/GitHub account after the three repositories have been pushed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/bootstrap.sh --catalog-repo OWNER/REPO --orders-repo OWNER/REPO [options]

This validates local AWS/GitHub login, configures GitHub variables/secrets, bootstraps CDK,
deploys PreviewPlatform, stores its GitHub OIDC role secret, then creates and verifies the
BaselineEnvironment through the exact GitHub Actions path used by normal main-branch pushes.

Options:
  --control-repo OWNER/REPO  Coordinator repository (default: this repository's origin)
  --region REGION            AWS region (default: us-east-2)
  --skip-baseline            Stop after shared platform setup
  -h, --help                 Show this help
EOF
}

catalog_repo=""
orders_repo=""
control_repo=""
region="us-east-2"
skip_baseline=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog-repo) catalog_repo="${2:?missing catalog repository}"; shift 2 ;;
    --orders-repo) orders_repo="${2:?missing orders repository}"; shift 2 ;;
    --control-repo) control_repo="${2:?missing control repository}"; shift 2 ;;
    --region) region="${2:?missing region}"; shift 2 ;;
    --skip-baseline) skip_baseline=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$catalog_repo" && -n "$orders_repo" ]] || { usage >&2; exit 2; }

project_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z "$control_repo" ]]; then
  control_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

bash "$project_root/scripts/configure_github.sh" \
  --catalog-repo "$catalog_repo" --orders-repo "$orders_repo" \
  --control-repo "$control_repo" --region "$region"
bash "$project_root/scripts/deploy_platform.sh" --control-repo "$control_repo" --region "$region"

if [[ "$skip_baseline" == false ]]; then
  bash "$project_root/scripts/request_preview.sh" \
    --control-repo "$control_repo" --region "$region" --service a --ref main
fi
