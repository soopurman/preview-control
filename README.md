# preview-control

The AWS CDK project and coordinator workflow for ephemeral FastAPI preview environments.

`catalog-service` and `orders-service` send branch lifecycle events here. Branches named `fg/<name>` become one combined environment; ordinary branches get independent service previews. The workflow resolves both refs, runs their full containerized CRUD tests, builds both images, publishes them to ECR, then deploys ECS/Fargate services behind an ALB.

`main` maintains `BaselineEnvironment`. Every preview snapshots its baseline PostgreSQL RDS instance immediately before deployment and restores a private, independent RDS instance from it. The source snapshot is deleted after restore and the preview database is deleted with its stack.

## Design at a glance

```text
catalog-service / orders-service
  branch push or deletion
          |
          v
GitHub Actions coordinator
  resolve paired refs -> test -> build -> push ECR -> deploy CDK
          |
          v
AWS shared platform
  VPC / ECS cluster / ECR / logs / GitHub OIDC role
          |
          +-- one application stack per environment
          |     +-- ALB /a/* -> catalog task
          |     +-- ALB /b/* -> orders task
          |     +-- isolated RDS PostgreSQL instance
          |
          +-- BaselineEnvironment is the source for preview snapshots
```

Each environment is independently addressable, has its own database credentials and database
instance, and can be created or removed without changing another environment. The shared
platform is deployed once; application stacks are created by the coordinator workflow.

## Feature group convention

Branches named `fg/<name>` represent one cross-service change. For example, `fg/checkout` in
`catalog-service` resolves to `catalog-service@fg/checkout + orders-service@main`; when the
matching branch appears in `orders-service`, the same environment is updated to use both feature
branches. Ordinary branch names are isolated per service (`catalog-login`, `orders-login`) and
never combine accidentally.

The coordinator always builds both services: a missing group branch resolves to `main`. When a
branch is deleted, it checks whether the other half of the group still exists and destroys the
environment only after both branches are gone. This makes branch deletion and merge cleanup safe
for multi-repository changes.

## Getting started and prerequisites

The scripts are POSIX-host friendly Bash and have been written to work on current Fedora and
macOS. They do not depend on Linux-only utilities or a global CDK installation.

### Local tools

Install these before running bootstrap or any operator script:

| Tool | Why it is needed | Recommended version |
| --- | --- | --- |
| Git | Clone and push the three repositories | Current Git 2.x |
| Bash | Runs the supplied scripts | Bash 3.2+ (the macOS built-in Bash is sufficient) |
| Python | Creates the isolated CDK virtual environment | Python 3.10+; 3.12 recommended, including `venv`/`pip` |
| Node.js/npm | `npx` obtains the pinned CDK CLI | Node 20 LTS+ |
| AWS CLI | Authenticates and queries/deploys AWS resources | AWS CLI v2 |
| GitHub CLI | Configures repository variables/secrets and watches Actions | Current `gh` |
| `jq` and `curl` | Parses API/Actions data and runs smoke tests | Current versions |

Docker Engine plus Docker Compose v2 are **only** required when running the FastAPI services
and their tests locally. They are not required for `bootstrap.sh`: the coordinator tests use
GitHub-hosted runners, which already provide Docker.

On Fedora, the distribution packages normally cover the required tools (for example,
`sudo dnf install git gh awscli jq python3 nodejs`). Install and enable Docker/Compose separately
if you want local container tests. On macOS, Homebrew provides the CLI prerequisites:

```bash
brew install git gh awscli jq python@3.12 node@20
# Optional, for local service containers and tests:
brew install --cask docker
```

Start Docker Desktop once after installing it on macOS. On either OS, confirm the essentials:

```bash
git --version
python3 --version
node --version
aws --version
gh --version
jq --version
```

### Accounts and access

1. Create or select an AWS account and region with the normal ECS, ECR, RDS, VPC,
   CloudFormation, IAM, and CloudWatch service quotas available. The scripts default to
   `us-east-2`, where this project’s RDS engine version has been validated.
2. Authenticate the AWS CLI before bootstrap. AWS IAM Identity Center/SSO is preferred for a
   human operator (`aws configure sso`, then `aws sso login`); a temporary IAM role/profile also
   works. The initial bootstrap identity needs permission to create this platform’s resources,
   including the GitHub OIDC provider and deployment role. Do not use a production account.
3. Authenticate the GitHub CLI with an account that has **admin** access to all three repositories:
   `gh auth login`. For private repositories, a classic token with the `repo` scope is the simplest
   option. It must be able to write Actions variables and secrets and dispatch/read workflows.
4. Push the submitted catalog, orders, and coordinator source to three repositories before
   bootstrap. The scripts configure their cross-repository wiring; they intentionally do not
   create repositories or overwrite source history.

## One-time AWS and GitHub setup

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

Service branch pushes are the normal interface. For a deterministic operator-triggered or recovery run, use
the same workflow explicitly and wait through the result:

```bash
# Rebuild the long-lived baseline from both main branches.
bash scripts/request_preview.sh --service a --ref main --control-repo OWNER/preview-control

# Resolve both fg/checkout branches into one Preview-fg-checkout stack, then wait and verify it.
bash scripts/request_preview.sh --service a --ref fg/checkout --control-repo OWNER/preview-control

# Re-check any environment later, including its public health and seeded data.
bash scripts/check_environment.sh Preview-fg-checkout
```

`check_environment.sh` prints the public ALB and Swagger URLs after checking `/a/health`,
`/b/health`, and the seeded `/items` lists. Individual script help documents all options:
`bash scripts/bootstrap.sh --help`.

See [CLEANUP.md](CLEANUP.md), [OPERATIONS.md](OPERATIONS.md), and [DECISIONS.md](DECISIONS.md).
