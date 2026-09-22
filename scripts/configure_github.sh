#!/usr/bin/env bash
# Configure the repository-to-repository wiring without ever printing the dispatch token.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/configure_github.sh --catalog-repo OWNER/REPO --orders-repo OWNER/REPO [options]

Options:
  --control-repo OWNER/REPO  Coordinator repository (default: this repository's origin)
  --region REGION            AWS region recorded for display only (default: us-east-2)
  -h, --help                 Show this help
EOF
}

catalog_repo=""
orders_repo=""
control_repo=""
region="us-east-2"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog-repo) catalog_repo="${2:?missing catalog repository}"; shift 2 ;;
    --orders-repo) orders_repo="${2:?missing orders repository}"; shift 2 ;;
    --control-repo) control_repo="${2:?missing control repository}"; shift 2 ;;
    --region) region="${2:?missing region}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$catalog_repo" && -n "$orders_repo" ]] || { usage >&2; exit 2; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
gh auth status >/dev/null

if [[ -z "$control_repo" ]]; then
  control_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

# GitHub's current OIDC subject uses immutable owner and repository IDs. Derive it rather
# than asking an operator to copy an easy-to-mistype value from a web page.
control_metadata=$(gh api "repos/$control_repo")
owner=$(jq -r '.owner.login' <<<"$control_metadata")
owner_id=$(jq -r '.owner.id' <<<"$control_metadata")
repository_name=$(jq -r '.name' <<<"$control_metadata")
repository_id=$(jq -r '.id' <<<"$control_metadata")
oidc_subject="repo:${owner}@${owner_id}/${repository_name}@${repository_id}:ref:refs/heads/main"

for repo in "$catalog_repo" "$orders_repo" "$control_repo"; do
  gh repo view "$repo" >/dev/null
done

gh variable set PREVIEW_CONTROL_REPOSITORY --repo "$catalog_repo" --body "$control_repo"
gh variable set PREVIEW_CONTROL_REPOSITORY --repo "$orders_repo" --body "$control_repo"
gh variable set SERVICE_A_REPOSITORY --repo "$control_repo" --body "$catalog_repo"
gh variable set SERVICE_B_REPOSITORY --repo "$control_repo" --body "$orders_repo"
gh variable set OIDC_SUBJECT --repo "$control_repo" --body "$oidc_subject"
gh variable set AWS_REGION --repo "$control_repo" --body "$region"

# This short-lived PAT is solely for GitHub cross-repository reads and repository_dispatch.
# AWS access is handled by the deployed OIDC role, never by this token.
dispatch_token=$(gh auth token)
for repo in "$catalog_repo" "$orders_repo" "$control_repo"; do
  printf '%s' "$dispatch_token" | gh secret set PREVIEW_DISPATCH_TOKEN --repo "$repo"
done

echo "GitHub wiring complete."
echo "  coordinator: $control_repo"
echo "  catalog:     $catalog_repo"
echo "  orders:      $orders_repo"
echo "  OIDC subject: $oidc_subject"
