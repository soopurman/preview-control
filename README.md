# preview-control

The AWS CDK project and coordinator workflow for ephemeral FastAPI preview environments.

`catalog-service` and `orders-service` send branch lifecycle events here. Branches named `fg/<name>` become one combined environment; ordinary branches get independent service previews. The workflow resolves both refs, runs their full containerized CRUD tests, builds both images, publishes them to ECR, then deploys ECS/Fargate services behind an ALB.

`main` maintains `BaselineEnvironment`. Every preview snapshots its baseline PostgreSQL RDS instance immediately before deployment and restores a private, independent RDS instance from it. The source snapshot is deleted after restore and the preview database is deleted with its stack.

## Initial setup

1. Set `SERVICE_A_REPOSITORY` and `SERVICE_B_REPOSITORY` Actions variables to the two repository names.
2. Set `PREVIEW_DISPATCH_TOKEN` as a fine-grained PAT secret in all three repos: control-repo contents read/write, service-repo contents read.
3. Set `OIDC_SUBJECT` in this repo to the exact immutable GitHub OIDC subject for its `main` branch.
4. Bootstrap CDK and deploy `PreviewPlatform` locally once. Set its `GitHubActionsRoleArn` output as Actions secret `AWS_DEPLOY_ROLE_ARN`.
5. Push `main` to create the baseline; then push `fg/demo` in one or both service repositories.

The Actions deployment role uses GitHub OIDC and short-lived AWS STS credentials—no long-lived AWS key is stored in GitHub. See [CLEANUP.md](CLEANUP.md), [DECISIONS.md](DECISIONS.md), and [DEMO.md](DEMO.md).
