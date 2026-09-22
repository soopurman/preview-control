#!/usr/bin/env python3
"""Resolve a preview event into exact source refs and a safe stack name.

This runs in the control repository. It deliberately asks GitHub for both branches on
every event instead of trusting a deleted-branch event payload.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def payload() -> dict:
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as event_file:
        event = json.load(event_file)
    if os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        inputs = event.get("inputs", {})
        return {"service": inputs["service"], "ref": inputs["ref"], "lifecycle": inputs["lifecycle"]}
    return event["client_payload"]


def exists(repo: str, ref: str) -> bool:
    url = f"https://api.github.com/repos/{repo}/git/ref/heads/{urllib.parse.quote(ref, safe='')}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def slug(value: str) -> str:
    value = re.sub(r"[^a-z0-9-]+", "-", value.lower()).strip("-")[:32].rstrip("-")
    if not value:
        raise ValueError("branch name does not yield a valid preview id")
    return value


def emit(**values: str) -> None:
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main() -> None:
    event = payload()
    service, ref = event["service"], event["ref"]
    if service not in {"a", "b"} or not ref:
        raise ValueError("event must identify service a/b and a branch")
    repos = {"a": os.environ["SERVICE_A_REPOSITORY"], "b": os.environ["SERVICE_B_REPOSITORY"]}

    if ref == "main":
        # This is the long-lived shared development baseline. Main builds are deliberately
        # routed through the same image-and-CDK path as previews.
        preview_id, lifecycle, a_ref, b_ref, stack_name, is_baseline = (
            "baseline", "baseline", "main", "main", "BaselineEnvironment", "true"
        )
    elif ref.startswith("fg/") and len(ref) > 3:
        group_ref = ref
        preview_id = slug(f"fg-{ref[3:]}")
        a_exists, b_exists = exists(repos["a"], group_ref), exists(repos["b"], group_ref)
        lifecycle = "upsert" if a_exists or b_exists else "destroy"
        a_ref = group_ref if a_exists else "main"
        b_ref = group_ref if b_exists else "main"
        stack_name, is_baseline = f"Preview-{preview_id}", "false"
    else:
        preview_id = slug(f"{service}-{ref}")
        source_exists = exists(repos[service], ref)
        lifecycle = "upsert" if source_exists else "destroy"
        a_ref = ref if service == "a" and source_exists else "main"
        b_ref = ref if service == "b" and source_exists else "main"
        stack_name, is_baseline = f"Preview-{preview_id}", "false"

    emit(
        lifecycle=lifecycle,
        preview_id=preview_id,
        stack_name=stack_name,
        is_baseline=is_baseline,
        service_a_ref=a_ref,
        service_b_ref=b_ref,
    )
    print(f"{lifecycle}: Preview-{preview_id} (catalog={a_ref}, orders={b_ref})")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Preview resolution failed: {error}", file=sys.stderr)
        raise
