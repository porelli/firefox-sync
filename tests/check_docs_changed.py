#!/usr/bin/env python3
"""Warn when a branch changes a feature and no docs.

Usage: python3 -I tests/check_docs_changed.py [--base REF] [--root DIR]

Compares HEAD with --base (default: the merge base of HEAD and main, origin/main when
there is no local main), as git diff BASE...HEAD. A change to a feature surface (FEATURES:
.env-example, the chart's values.yaml, admin/templates/, admin/*.go but the tests, db/,
compose/, config/quadlet/, setup/) with no change under docs/ and to no README.md gets a
warning, unless a commit of BASE..HEAD has a line

    Docs: none (<reason>)

In GitHub Actions the warning is a ::warning annotation. Always exits 0: it is a reminder,
not a gate (docs/development/testing.md#docs-with-the-features). Stdlib only.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

FEATURES = (
    re.compile(r"^\.env-example$"),
    re.compile(r"^charts/firefox-sync/values\.yaml$"),
    re.compile(r"^admin/templates/"),
    re.compile(r"^admin/[^/]+\.go$"),
    re.compile(r"^db/"),
    re.compile(r"^compose/"),
    re.compile(r"^config/quadlet/"),
    re.compile(r"^setup/"),
)
NO_DOCS = re.compile(r"^Docs: none \(\s*[^\s)].*\)\s*$", re.M)


def is_feature(path):
    if path.startswith("admin/") and path.endswith("_test.go"):
        return False
    return any(p.search(path) for p in FEATURES)


def is_docs(path):
    return path.startswith("docs/") or path.rsplit("/", 1)[-1] == "README.md"


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


def default_base(root):
    for ref in ("main", "origin/main"):
        try:
            return git(root, "merge-base", "HEAD", ref).strip()
        except subprocess.CalledProcessError:
            continue
    return None


def review(files, messages):
    """The feature files that need docs: [] when docs changed too or a commit says Docs: none."""
    if any(is_docs(f) for f in files) or NO_DOCS.search(messages):
        return []
    return [f for f in files if is_feature(f)]


def warn(message):
    if os.environ.get("GITHUB_ACTIONS") == "true":
        text = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::warning title=Docs not updated::{text}")
    else:
        print(f"warning: {message}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--base", help="the commit to compare with (default: the merge base with main)")
    p.add_argument("--root", default=Path(__file__).resolve().parent.parent, help="the repository (default: this one)")
    args = p.parse_args(argv)
    base = args.base
    if base and set(base) == {"0"}:
        base = None  # a new branch: GitHub's "before" is all zeros
    if base:
        try:
            git(args.root, "rev-parse", "--verify", "--quiet", base + "^{commit}")
        except subprocess.CalledProcessError:
            print(f"docs: {base} is not in this clone (a force push?), comparing with main", file=sys.stderr)
            base = None
    try:
        if not base:
            base = default_base(args.root)
        if not base:
            warn("no main to compare with: the docs check of this branch did not run")
            return 0
        files = [f for f in git(args.root, "diff", "--name-only", f"{base}...HEAD").splitlines() if f]
        messages = git(args.root, "log", "--format=%B", f"{base}..HEAD")
    except subprocess.CalledProcessError as e:
        warn(f"git failed, the docs check of this branch did not run: {(e.stderr or '').strip()}")
        return 0
    missing = review(files, messages)
    if missing:
        warn(f"{len(missing)} feature file(s) changed since {base[:12]} without a change under docs/ or to a README.md: "
             + ", ".join(missing)
             + ". Update the page that documents them, or add a line 'Docs: none (<reason>)' to a commit message"
             + " (docs/development/testing.md#docs-with-the-features).")
    else:
        print(f"docs: {len(files)} file(s) changed since {base[:12]}, nothing to say", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
