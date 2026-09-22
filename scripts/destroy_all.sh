#!/usr/bin/env bash
# Deliberately explicit: this destroys every challenge resource in the configured account/region.
set -euo pipefail

if [[ "${1:-}" != "--confirm" ]]; then
  echo "Refusing to run. This destroys all Preview-* stacks, BaselineEnvironment, temporary snapshots, and PreviewPlatform."
  echo "Re-run: bash scripts/destroy_all.sh --confirm"
  exit 2
fi

AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_REGION
cd "$(dirname "$0")/../infra"

destroy_stack() {
  local stack_name="$1"
  shift
  if aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
    echo "Destroying $stack_name"
    npx --yes aws-cdk destroy "$stack_name" --force "$@"
  fi
}

# Destroy application stacks first; the shared VPC/cluster/ECR stack remains until last.
preview_stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, 'Preview-')].StackName" --output text)
for stack in $preview_stacks; do
  preview_id="${stack#Preview-}"
  destroy_stack "$stack" \
    -c preview_id="$preview_id" \
    -c snapshot_identifier=cleanup-placeholder \
    -c service_a_image=placeholder.invalid/a:cleanup \
    -c service_b_image=placeholder.invalid/b:cleanup
done

destroy_stack BaselineEnvironment \
  -c baseline=true \
  -c preview_id=baseline \
  -c service_a_image=placeholder.invalid/a:cleanup \
  -c service_b_image=placeholder.invalid/b:cleanup

# A failed CI run can leave a manual source snapshot before CDK receives it.
snapshots=$(aws rds describe-db-snapshots --snapshot-type manual \
  --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, 'preview-seed-')].DBSnapshotIdentifier" --output text)
for snapshot in $snapshots; do
  if [[ "$snapshot" != "None" ]]; then
    echo "Deleting temporary snapshot $snapshot"
    aws rds delete-db-snapshot --db-snapshot-identifier "$snapshot"
  fi
done

destroy_stack PreviewPlatform -c github_subject="${OIDC_SUBJECT:-repo:OWNER/preview-control:ref:refs/heads/main}"
echo "Cleanup request complete. Check CloudFormation and RDS once deletions finish."
