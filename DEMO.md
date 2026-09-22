# Suggested five-minute demo

1. Show the three repositories and `fg/<name>` convention.
2. Show the coordinator’s test gate and ref resolver.
3. Run `bash scripts/request_preview.sh --service a --ref fg/demo --control-repo OWNER/preview-control` to show an operator does not need an ad-hoc command transcript.
4. Show the RDS snapshot/restore, ECR image pushes and CDK preview stack.
5. Visit the ALB `/a/docs` and `/b/docs` (or `/a/health`, `/a/items`, `/b/health`) endpoints.
6. Push `fg/demo` to the second service; show the same preview using both feature images.
7. Delete branches and show automatic teardown; finish with `CLEANUP.md`.
