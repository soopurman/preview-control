# Operating the preview platform

The coordinator is operated through GitHub branch events. A push to `main` refreshes the
long-lived `BaselineEnvironment`; a push to a feature branch creates or updates an isolated
application stack after both selected service revisions pass their containerized CRUD tests.

## Create or refresh an environment

For normal development, push the relevant branch. For an explicit operator-triggered run:

```bash
# Refresh the baseline from both service main branches.
bash scripts/request_preview.sh --service a --ref main --control-repo OWNER/preview-control

# Resolve both fg/checkout branches into Preview-fg-checkout.
bash scripts/request_preview.sh --service a --ref fg/checkout --control-repo OWNER/preview-control
```

The command waits for the workflow conclusion, CloudFormation completion, API readiness and
non-empty seeded item collections. It prints the environment URL and the `/a/docs` and `/b/docs`
Swagger URLs. The paired branch resolver determines which service revisions are used; the local
`--service` value only identifies the event source.

To inspect an existing environment without changing it:

```bash
bash scripts/check_environment.sh Preview-fg-checkout
```

## Lifecycle and failure handling

The workflow uses a concurrency group per environment, so overlapping updates to the same feature
group are serialized. A failed test gate prevents image publication and infrastructure changes.
For a failed CloudFormation deployment, inspect the workflow and stack events, correct the source
or configuration, and rerun the same branch event. An incomplete source snapshot is removed in an
`always()` cleanup step; orphaned snapshots can be removed with the account cleanup procedure.

## Teardown

Delete or merge the feature branches. The coordinator verifies both repositories before destroying
the paired stack. To remove all platform resources deliberately, follow [CLEANUP.md](CLEANUP.md).
