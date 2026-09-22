#!/usr/bin/env python3
import os

import aws_cdk as cdk

from preview_platform.stacks import PlatformStack, PreviewEnvironmentStack, preview_stack_name


app = cdk.App()
account = os.environ.get("CDK_DEFAULT_ACCOUNT")
region = app.node.try_get_context("aws_region") or os.environ.get("CDK_DEFAULT_REGION", "us-east-2")
env = cdk.Environment(account=account, region=region)

platform = PlatformStack(
    app,
    "PreviewPlatform",
    env=env,
    github_subject=app.node.try_get_context("github_subject")
    or "repo:OWNER/preview-control:ref:refs/heads/main",
)

preview_id = app.node.try_get_context("preview_id")
if preview_id:
    is_baseline = app.node.try_get_context("baseline") == "true"
    preview = PreviewEnvironmentStack(
        app,
        "BaselineEnvironment" if is_baseline else preview_stack_name(preview_id),
        env=env,
        platform=platform,
        preview_id=preview_id,
        is_baseline=is_baseline,
        snapshot_identifier=app.node.try_get_context("snapshot_identifier"),
        service_a_image=app.node.try_get_context("service_a_image"),
        service_b_image=app.node.try_get_context("service_b_image"),
    )
    preview.add_dependency(platform)

app.synth()
