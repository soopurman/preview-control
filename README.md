# preview-control

The AWS CDK project and coordinator workflow for ephemeral FastAPI preview environments.

`catalog-service` and `orders-service` send branch lifecycle events here. Branches named `fg/<name>` become one combined environment; ordinary branches get independent service previews. The workflow resolves both refs, runs their full containerized CRUD tests, builds both images, publishes them to ECR, then deploys ECS/Fargate services behind an ALB.

`main` maintains `BaselineEnvironment`. Every preview snapshots its baseline PostgreSQL RDS instance immediately before deployment and restores a private, independent RDS instance from it. The source snapshot is deleted after restore and the preview database is deleted with its stack.

## Repeatable setup from a fresh account

The source code must first exist in three GitHub repositories: this coordinator plus the
catalog and orders service repositories. From a local clone of this repository, authenticated
with `gh auth login` and AWS CLI credentials, one command performs the account setup and
waits for an API-level baseline smoke test:

```bash
bash scripts/bootstrap.sh \
  --catalog-repo OWNER/catalog-service \
  --orders-repo OWNER/orders-service \
  --control-repo OWNER/preview-control \
  --region us-east-2
```

It deliberately automates the operational steps that CDK alone does not own:

1. Validates the local `gh` and AWS identities.
2. Derives the immutable GitHub OIDC subject, configures all Actions variables, and stores the
   GitHub dispatch token as a secret without printing it.
3. Creates/updates the CDK bootstrap resources and `PreviewPlatform`, then sets the deployed
   `GitHubActionsRoleArn` as `AWS_DEPLOY_ROLE_ARN` in the coordinator repository.
4. Dispatches the normal coordinator workflow for `main`, waits for the workflow conclusion,
   waits for CloudFormation, and verifies both deployed FastAPI services and their seeded data.

The script is idempotent for the same repositories and AWS account. It does create AWS
resources and GitHub configuration, so use `--skip-baseline` if you only want to establish the
shared platform first. The deployment role uses GitHub OIDC and short-lived AWS STS credentials;
no AWS access key is stored in GitHub.

## Operating the deployment

Service branch pushes are the normal interface. For a deterministic demo or recovery run, use
the same workflow explicitly and wait through the result:

```bash
# Rebuild the long-lived baseline from both main branches.
bash scripts/request_preview.sh --service a --ref main --control-repo OWNER/preview-control

# Resolve both fg/demo branches into one Preview-fg-demo stack, then wait and verify it.
bash scripts/request_preview.sh --service a --ref fg/demo --control-repo OWNER/preview-control

# Re-check any environment later, including its public health and seeded data.
bash scripts/check_environment.sh Preview-fg-demo
```

`check_environment.sh` prints the public ALB and Swagger URLs after checking `/a/health`,
`/b/health`, and the seeded `/items` lists. Individual script help documents all options:
`bash scripts/bootstrap.sh --help`.

See [CLEANUP.md](CLEANUP.md), [DECISIONS.md](DECISIONS.md), and [DEMO.md](DEMO.md).
