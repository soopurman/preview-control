# Decommissioning the preview platform

## Ordinary preview cleanup

Delete or merge a feature branch. The coordinator checks both repositories and destroys a preview only when no paired feature branch remains.

## Delete the complete platform

```bash
cd preview-control
# The bootstrap script derived this once; no manually copied OIDC subject is needed here.
export OIDC_SUBJECT="$(gh variable get OIDC_SUBJECT --repo OWNER/preview-control)"
bash scripts/destroy_all.sh --confirm
```

This explicitly destroys preview stacks, the baseline, orphaned seed snapshots, then the platform
(VPC, ECS cluster, ECR repositories, logs and CI role). Verify that CloudFormation, RDS DB
instances/manual snapshots, ECS services, ECR images and CloudWatch logs are empty afterward.
The command is intentionally account-wide; use it only in an account dedicated to this platform.
