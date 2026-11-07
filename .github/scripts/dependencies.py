#!/usr/bin/env python3
"""The gate of Dependabot's pull requests (.github/workflows/dependencies.yml).

Usage:
  dependencies.py decide --update-type TYPE --base REF --head SHA
  dependencies.py wait --base REF --head SHA --branch BRANCH [--timeout S] [--interval S]
  dependencies.py dispatch --base REF --head SHA --ref main

- decide: whether the pull request may be merged without a human: a semver major, minor or
  patch update (dependabot/fetch-metadata's update-type, the highest of a group) that moves no
  action pinned by commit. Prints merge=true|false and why=..., for GITHUB_OUTPUT.
- wait: until every workflow run of the head commit completed, then exits 0 when each passed.
  The workflows a push of the changed files (BASE...HEAD) starts must each have a run of the
  commit: one that has none (a rebase whose own push changed other files) is started by hand
  (workflow_dispatch) on the branch.
- dispatch: after the merge, the workflows a push of those files to main would have started,
  started by hand on main: a merge with GITHUB_TOKEN starts no push workflow.

Which workflows a push starts: their on.push filters (branches, paths, paths-ignore), read
with yq, matched as GitHub does. docs/development/dependencies.md. Needs gh, git, yq.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

WORKFLOWS = Path(".github/workflows")
SELF = ".github/workflows/dependencies.yml"
# on main: release.yml's push run plans nothing (the weekly runs and tags release)
NOT_ON_MAIN = {".github/workflows/release.yml"}
# a major one too: CI is what decides (the test jobs a push of its files starts, every one passed)
MERGE = {"version-update:semver-major", "version-update:semver-minor", "version-update:semver-patch"}
SHA_PIN = re.compile(r"^\+.*\buses:\s*[^\s#]+@[0-9a-f]{40}\b", re.M)
PASSED = {"success", "skipped", "neutral"}


def glob_regex(pattern):
    """A filter pattern of GitHub Actions (*, **, ?, +, [..]) as a regex of a whole path."""
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
            continue
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "+":
            out.append("+")
        elif c == "[":
            j = pattern.find("]", i)
            if j < 0:
                out.append(re.escape(c))
            else:
                out.append(pattern[i:j + 1])
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def matches(patterns, path):
    """GitHub's filter: the last pattern that matches decides, a !pattern excludes."""
    hit = False
    for p in patterns:
        neg = p.startswith("!")
        if glob_regex(p[1:] if neg else p).match(path):
            hit = not neg
    return hit


def push_filter(on):
    """The push filter of a workflow's `on` (a string, a list or a mapping): None when it has no
    push trigger, else a dict (empty: every push)."""
    if isinstance(on, str):
        on = [on]
    if isinstance(on, list):
        return {} if "push" in on else None
    if not isinstance(on, dict) or "push" not in on:
        return None
    return on["push"] or {}


def starts(on, branch, files):
    """Whether a push of files to branch starts the workflow."""
    f = push_filter(on)
    if f is None:
        return False
    if "branches" in f and not matches(f["branches"], branch):
        return False
    if "branches-ignore" in f and matches(f["branches-ignore"], branch):
        return False
    if not files:
        return True
    if "paths" in f:
        return any(matches(f["paths"], x) for x in files)
    if "paths-ignore" in f:
        return not all(matches(f["paths-ignore"], x) for x in files)
    return True


def dispatchable(on):
    if not on:
        return False
    if isinstance(on, str):
        on = [on]
    return "workflow_dispatch" in on


def needed(workflows, branch, files, main=False):
    """The workflow paths a push of files to branch starts, but this one (and on main, those
    whose push run does nothing there)."""
    out = []
    for path, on in sorted(workflows.items()):
        if path == SELF or (main and path in NOT_ON_MAIN):
            continue
        if starts(on, branch, files):
            out.append(path)
    return out


def decide(update_type, diff):
    """(merge?, why) for a Dependabot pull request."""
    if update_type not in MERGE:
        return False, f"update type {update_type or 'unknown'}: left for a human to review and merge"
    pins = SHA_PIN.findall(diff)
    if pins:
        return False, ("it moves an action pinned by commit (a security pin): left for a human: "
                       + "; ".join(p[1:].strip() for p in pins))
    return True, f"{update_type}: merged once CI passed"


def verdict(runs, needed_paths):
    """(state, detail) of the runs of a commit: pending (some running, or a needed workflow
    without a run: missing), failed, or passed. The latest run per workflow and event counts."""
    latest = {}
    for r in sorted(runs, key=lambda r: (r.get("created_at") or "", r.get("id") or 0)):
        path = (r.get("path") or r.get("name") or "").split("@")[0]
        if path == SELF or r.get("event") == "dynamic":
            continue
        latest[(path, r.get("event"))] = r
    have = {p for p, _ in latest}
    missing = [p for p in needed_paths if p not in have]
    pending = [r for r in latest.values() if r.get("status") != "completed"]
    if pending or missing:
        return "pending", {"pending": [r.get("name") for r in pending], "missing": missing}
    failed = [r for r in latest.values() if r.get("conclusion") not in PASSED]
    if failed:
        return "failed", [f"{r.get('name')} ({r.get('conclusion')}) {r.get('html_url')}" for r in failed]
    return "passed", sorted(f"{p} ({e})" for p, e in latest)


# --- the repository, GitHub ---

def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def changed_files(base, head):
    return [f for f in sh("git", "diff", "--no-renames", "--name-only", f"{base}...{head}").splitlines() if f]


def load_workflows():
    out = {}
    for p in sorted(WORKFLOWS.glob("*.y*ml")):
        out[str(p)] = json.loads(sh("yq", "-o=json", ".on", str(p)) or "null")
    return out


def runs_of(repo, sha):
    data = json.loads(sh("gh", "api", f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100"))
    return data.get("workflow_runs") or []


def dispatch(repo, path, ref):
    sh("gh", "workflow", "run", Path(path).name, "--repo", repo, "--ref", ref)
    print(f"dependencies: started {path} on {ref}", file=sys.stderr)


def output(**values):
    for k, v in values.items():
        print(f"{k}={v}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--update-type", default="")
    for s in (d, sub.add_parser("wait"), sub.add_parser("dispatch")):
        s.add_argument("--base", required=True)
        s.add_argument("--head", required=True)
    w = sub.choices["wait"]
    w.add_argument("--branch", required=True)
    w.add_argument("--timeout", type=int, default=320 * 60)
    w.add_argument("--interval", type=int, default=120)
    # a run the push started appears within seconds; after this, a needed one is started by hand
    w.add_argument("--grace", type=int, default=180)
    sub.choices["dispatch"].add_argument("--ref", required=True)
    args = p.parse_args(argv)
    repo = os.environ.get("GITHUB_REPOSITORY", "")

    if args.cmd == "decide":
        merge, why = decide(args.update_type, sh("git", "diff", f"{args.base}...{args.head}"))
        output(merge=str(merge).lower(), why=why)
        return 0

    files = changed_files(args.base, args.head)
    workflows = load_workflows()
    if args.cmd == "dispatch":
        paths = needed(workflows, args.ref, files, main=True)
        for path in paths:
            if dispatchable(workflows[path]):
                dispatch(repo, path, args.ref)
            else:
                print(f"::warning::{path} has no workflow_dispatch: it does not run on {args.ref} for this merge")
        return 0

    paths = needed(workflows, args.branch, files)
    print(f"dependencies: {len(files)} file(s) changed; workflows needed: {', '.join(paths)}", file=sys.stderr)
    start, started = time.time(), set()
    while True:
        state, detail = verdict(runs_of(repo, args.head), paths)
        if state == "passed":
            print("dependencies: CI passed: " + ", ".join(detail), file=sys.stderr)
            return 0
        if state == "failed":
            print("::error::CI of the pull request did not pass: " + "; ".join(detail))
            return 1
        if time.time() - start > args.grace:
            for path in detail["missing"]:
                if path in started:
                    continue
                if not dispatchable(workflows.get(path)):
                    print(f"::error::{path} has no run of {args.head[:12]} and no workflow_dispatch")
                    return 1
                dispatch(repo, path, args.branch)
                started.add(path)
        if time.time() - start > args.timeout:
            print(f"::error::CI of {args.head[:12]} still running after {args.timeout // 60} min: {detail}")
            return 1
        print(f"dependencies: waiting: {detail}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
