# Decommissioning the challenge environment

## Ordinary preview cleanup

Delete or merge a feature branch. The coordinator checks both repositories and destroys a preview only when no paired feature branch remains.

## Delete everything after the demo

```bash
cd preview-control
python3 -m venv infra/.venv
source infra/.venv/bin/activate
pip install -r infra/requirements.txt
export GITHUB_OIDC_SUBJECT='repo:OWNER@OWNER_ID/preview-control@REPOSITORY_ID:ref:refs/heads/main'
bash scripts/destroy_all.sh --confirm
```

This explicitly destroys preview stacks, the baseline, orphaned seed snapshots, then the platform (VPC, ECS cluster, ECR repositories, logs and CI role). Verify that CloudFormation, RDS DB instances/manual snapshots, ECS services, ECR images and CloudWatch logs are empty afterward. Never use it in a real production account.
