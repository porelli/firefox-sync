#!/usr/bin/env python3
"""Self-test of tests/check_docs_changed.py on throwaway repositories: python3 -I tests/test_check_docs_changed.py"""

import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("changed", Path(__file__).resolve().parent / "check_docs_changed.py")
changed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changed)


CHANGELOG = "# Changelog\n\n## Unreleased\n\n### Added\n\n### Fixed\n"


class Rules(unittest.TestCase):
    def test_features(self):
        for f in (".env-example", "charts/firefox-sync/values.yaml", "admin/templates/overview.html", "admin/web.go",
                  "db/mysql/init/x.sql", "compose/sync.yml", "config/quadlet/x.container", "setup/x.sh"):
            self.assertTrue(changed.is_feature(f), f)
        for f in ("admin/web_test.go", "admin/testdata/x.jsonl", "admin/static/x.css", "tests/e2e.sh",
                  "charts/firefox-sync/templates/admin.yaml", "docs/admin/README.md", "mkdocs.yml"):
            self.assertFalse(changed.is_feature(f), f)

    def test_docs(self):
        for f in ("docs/admin/monitoring.md", "README.md", "charts/firefox-sync/README.md", "docs/images/x.png"):
            self.assertTrue(changed.is_docs(f), f)
        self.assertFalse(changed.is_docs("mkdocs.yml"))

    def test_review(self):
        self.assertEqual(changed.review(["admin/web.go", "tests/x.py"], "feat: x\n"), ["admin/web.go"])
        self.assertEqual(changed.review(["admin/web.go", "docs/admin/alerts.md"], ""), [])
        self.assertEqual(changed.review(["admin/web.go"], "fix: x\n\nDocs: none (a typo in a log line)\n"), [])
        # the line alone, with a reason
        self.assertEqual(changed.review(["admin/web.go"], "Docs: none (only a comment (and a log line))\n"), [])
        self.assertEqual(changed.review(["admin/web.go"], "Docs: none\n"), ["admin/web.go"])
        self.assertEqual(changed.review(["admin/web.go"], "Docs: none ( )\n"), ["admin/web.go"])
        self.assertEqual(changed.review(["admin/web.go"], "see Docs: none (x) below\n"), ["admin/web.go"])
        self.assertEqual(changed.review(["tests/x.py"], ""), [])

    def test_review_changelog(self):
        entry = CHANGELOG.replace("### Fixed\n", "### Fixed\n\n- The keep-alive.\n")
        self.assertEqual(changed.review_changelog(["admin/web.go"], "", CHANGELOG, CHANGELOG), ["admin/web.go"])
        self.assertEqual(changed.review_changelog(["admin/web.go"], "", CHANGELOG, entry), [])
        self.assertEqual(changed.review_changelog(["admin/web.go"], "", None, entry), [])
        self.assertEqual(changed.review_changelog(["admin/web.go"], "", None, None), ["admin/web.go"])
        # an entry already there before the branch is not the branch's
        self.assertEqual(changed.review_changelog(["admin/web.go"], "", entry, entry), ["admin/web.go"])
        self.assertEqual(changed.review_changelog(["admin/web.go"], "x\nChangelog: none (a refactor)\n", None, None), [])
        self.assertEqual(changed.review_changelog(["admin/web.go"], "Changelog: none\n", None, None), ["admin/web.go"])
        self.assertEqual(changed.review_changelog(["tests/x.py"], "", None, None), [])


def git(root, *args):
    subprocess.run(["git", "-C", root, *args], check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
                            GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull))


def commit(root, files, message):
    for name, text in files.items():
        p = Path(root) / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)


def run(root, *args, actions=False):
    out = io.StringIO()
    with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true" if actions else ""}), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = changed.main(["--root", root, *args])
    return code, out.getvalue()


class Branch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        git(self.root, "init", "-q", "-b", "main")
        commit(self.root, {"admin/web.go": "package main\n", "docs/a.txt": "# A\n", "CHANGELOG.md": CHANGELOG}, "init")
        git(self.root, "checkout", "-q", "-b", "topic")

    def tearDown(self):
        self.tmp.cleanup()

    def test_feature_without_docs(self):
        commit(self.root, {"admin/web.go": "package main // x\n"}, "feat: x")
        code, out = run(self.root, actions=True)
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("::warning title=Docs not updated::1 feature file(s)"), out)
        self.assertIn("admin/web.go", out)

    def test_docs_in_another_commit(self):
        commit(self.root, {"admin/web.go": "package main // x\n"}, "feat: x")
        commit(self.root, {"docs/a.txt": "# A\nmore\n", "CHANGELOG.md": CHANGELOG + "\n- x\n"}, "docs: x")
        self.assertEqual(run(self.root), (0, ""))

    def test_docs_none(self):
        commit(self.root, {"compose/sync.yml": "x: 1\n"},
               "fix: x\n\nDocs: none (an internal rename)\nChangelog: none (an internal rename)")
        self.assertEqual(run(self.root), (0, ""))

    def test_changelog(self):
        # docs, but no entry: the changelog's warning alone
        commit(self.root, {"admin/web.go": "package main // x\n", "docs/a.txt": "# A\nmore\n"}, "feat: x")
        code, out = run(self.root, actions=True)
        self.assertTrue(out.startswith("::warning title=Changelog not updated::1 feature file(s)"), out)
        self.assertNotIn("Docs not updated", out)
        # an entry under Unreleased
        commit(self.root, {"CHANGELOG.md": CHANGELOG.replace("### Added\n", "### Added\n\n- A QR code.\n")}, "docs: x")
        self.assertEqual(run(self.root), (0, ""))

    def test_changelog_released_section_does_not_count(self):
        commit(self.root, {"admin/web.go": "package main // x\n", "docs/a.txt": "# A\nmore\n",
                           "CHANGELOG.md": CHANGELOG + "\n## v2026.11.02 — 2026-11-02\n\n- x\n"}, "feat: x")
        self.assertIn("Changelog: none (<reason>)", run(self.root)[1])

    def test_changelog_none(self):
        commit(self.root, {"admin/web.go": "package main // x\n", "docs/a.txt": "# A\nmore\n"},
               "refactor: x\n\nChangelog: none (nothing anybody sees)")
        self.assertEqual(run(self.root), (0, ""))

    def test_push_range(self):
        # the base of a push: only what that push brought; the docs of an earlier push do not count
        commit(self.root, {"docs/a.txt": "# A\nmore\n"}, "docs: x")
        git(self.root, "tag", "pushed")
        commit(self.root, {".env-example": "X=1\n"}, "feat: x")
        code, out = run(self.root, "--base", "pushed")
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("warning: 1 feature file(s)"), out)
        self.assertIn(".env-example", out)

    def test_new_branch_and_unknown_base(self):
        commit(self.root, {"setup/x.sh": "x\n"}, "feat: x")
        for base in ("0" * 40, "1234567890abcdef1234567890abcdef12345678"):
            code, out = run(self.root, "--base", base)
            self.assertEqual(code, 0)
            self.assertIn("setup/x.sh", out)

    def test_no_main(self):
        git(self.root, "branch", "-q", "-m", "main", "trunk")
        code, out = run(self.root)
        self.assertEqual(code, 0)
        self.assertIn("did not run", out)


if __name__ == "__main__":
    unittest.main()
