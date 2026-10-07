"""Run the nightly build only when the current commit lacks a successful build.

Commit statuses provide a small, persistent marker without storing build artifacts.
The latest status is set to pending before each attempt, then success or failure
after all platform jobs complete. A failed or interrupted build is retried nightly.
"""

import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen


CONTEXT = "codex-bridge-desktop/platform-builds"


def api_json(method, path, payload=None):
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(
        base + path,
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def status_path():
    return "/repos/{}/statuses/{}".format(
        os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    )


def run_url():
    return "{}/{}/actions/runs/{}".format(
        os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/"),
        os.environ["GITHUB_REPOSITORY"],
        os.environ["GITHUB_RUN_ID"],
    )


def latest_build_state(statuses):
    for status in statuses:
        if status.get("context") == CONTEXT:
            return status.get("state")
    return None


def write_status(state, description):
    api_json(
        "POST",
        status_path(),
        {
            "state": state,
            "context": CONTEXT,
            "description": description,
            "target_url": run_url(),
        },
    )


def gate():
    event = os.environ["GITHUB_EVENT_NAME"]
    if event not in ("schedule", "workflow_dispatch"):
        raise ValueError("Unexpected workflow event: " + event)

    if event == "schedule":
        path = "/repos/{}/commits/{}/status".format(
            os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
        )
        status = api_json("GET", path)
        if latest_build_state(status["statuses"]) == "success":
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write("build=false\n")
            print("Current commit already has a successful three-platform build; skipping.")
            return

    write_status("pending", "Windows, Ubuntu and macOS build in progress")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write("build=true\n")
    print("Building current commit on all three platforms.")


def record():
    success = (
        os.environ["WINDOWS_RESULT"] == "success"
        and os.environ["UNIX_RESULT"] == "success"
    )
    if success:
        write_status("success", "Windows, Ubuntu and macOS builds passed")
        print("Recorded a successful three-platform build.")
    else:
        write_status("failure", "At least one platform build did not pass")
        print("Recorded a failed build; the next nightly run will retry.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("gate", "record"):
        raise SystemExit("Usage: ci_build_gate.py gate|record")
    if sys.argv[1] == "gate":
        gate()
    else:
        record()
