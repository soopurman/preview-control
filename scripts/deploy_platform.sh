#!/usr/bin/env bash
# Bootstrap CDK if needed, deploy the shared platform, and publish its OIDC role to Actions.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/deploy_platform.sh [options]

Options:
  --control-repo OWNER/REPO  Coordinator repository (default: this repository's origin)
  --region REGION            AWS region (default: us-east-2)
  --oidc-subject SUBJECT     Required when no OIDC_SUBJECT GitHub variable exists
  -h, --help                 Show this help
EOF
}

control_repo=""
region="us-east-2"
oidc_subject=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-repo) control_repo="${2:?missing control repository}"; shift 2 ;;
    --region) region="${2:?missing region}"; shift 2 ;;
    --oidc-subject) oidc_subject="${2:?missing OIDC subject}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "AWS CLI is required." >&2; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required." >&2; exit 1; }
aws sts get-caller-identity >/dev/null
gh auth status >/dev/null
if [[ -z "$control_repo" ]]; then
  control_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi
if [[ -z "$oidc_subject" ]]; then
  oidc_subject=$(gh variable get OIDC_SUBJECT --repo "$control_repo")
fi
[[ -n "$oidc_subject" ]] || { echo "OIDC subject is required; run configure_github.sh first." >&2; exit 1; }

project_root=$(cd "$(dirname "$0")/.." && pwd)
infra_dir="$project_root/infra"
account_id=$(aws sts get-caller-identity --query Account --output text)
venv_dir="$infra_dir/.venv"

python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install --quiet --upgrade pip
"$venv_dir/bin/python" -m pip install --quiet -r "$infra_dir/requirements.txt"

export PATH="$venv_dir/bin:$PATH"
export AWS_REGION="$region"
export AWS_DEFAULT_REGION="$region"
cd "$infra_dir"
npx --yes aws-cdk@2.1142.0 bootstrap "aws://${account_id}/${region}"
npx --yes aws-cdk@2.1142.0 deploy PreviewPlatform --require-approval never -c github_subject="$oidc_subject"

role_arn=$(aws cloudformation describe-stacks --stack-name PreviewPlatform \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsRoleArn'].OutputValue" --output text)
[[ -n "$role_arn" && "$role_arn" != "None" ]] || { echo "Platform role output was missing." >&2; exit 1; }
printf '%s' "$role_arn" | gh secret set AWS_DEPLOY_ROLE_ARN --repo "$control_repo"
echo "PreviewPlatform deployed and GitHub Actions role configured: $role_arn"
