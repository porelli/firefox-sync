#!/usr/bin/env python3
"""Self-test of .github/scripts/dependencies.py, the gate of Dependabot's pull requests: the
merge decision, GitHub's push filters, and the verdict on a commit's runs, without the network.
With yq installed, also which of this repository's workflows a change starts.
python3 -I tests/test_dependencies.py"""

import importlib.util
import os
import shutil
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("dependencies", ROOT / ".github/scripts/dependencies.py")
dep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dep)


class Decide(unittest.TestCase):
    def test_minor_patch_merge(self):
        for t in ("version-update:semver-minor", "version-update:semver-patch"):
            self.assertTrue(dep.decide(t, "+go 1.26\n")[0], t)

    def test_major_unknown_manual(self):
        for t in ("version-update:semver-major", "", "something-new"):
            merge, why = dep.decide(t, "")
            self.assertFalse(merge, t)
            self.assertIn("left for a human", why)

    def test_sha_pin_manual(self):
        diff = ("-        uses: azure/setup-helm@9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310 # v5.0.1\n"
                "+        uses: azure/setup-helm@0123456789abcdef0123456789abcdef01234567 # v5.0.2\n")
        merge, why = dep.decide("version-update:semver-patch", diff)
        self.assertFalse(merge)
        self.assertIn("pinned by commit", why)
        # a removed pin alone, or a tag: no pin moved in
        self.assertTrue(dep.decide("version-update:semver-patch", diff.splitlines()[0] + "\n+ uses: a/b@v5\n")[0])


class Filters(unittest.TestCase):
    def test_globs(self):
        m = dep.matches
        self.assertTrue(m(["admin/**"], "admin/go.mod"))
        self.assertTrue(m(["admin/**"], "admin/templates/x.html"))
        self.assertFalse(m(["admin/**"], "docs/admin/x.md"))
        self.assertTrue(m(["**/README.md"], "README.md"))
        self.assertTrue(m(["**/README.md"], "config/quadlet/README.md"))
        self.assertTrue(m(["tests/helm*"], "tests/helm-fxa.sh"))
        self.assertFalse(m(["tests/helm*"], "tests/helm/values.yaml"))
        self.assertTrue(m(["'**'".strip("'")], "dependabot/go_modules/admin/x-1.2"))
        self.assertFalse(m(["docs/**", "!docs/backups.md"], "docs/backups.md"))

    def test_starts(self):
        on = {"workflow_dispatch": None, "push": {"branches": ["**"], "paths": ["admin/**"]}}
        self.assertTrue(dep.starts(on, "main", ["admin/go.sum"]))
        self.assertFalse(dep.starts(on, "main", ["docs/x.md"]))
        ign = {"push": {"branches": ["main", "**"], "paths-ignore": ["docs/development/**", "**/README.md"]}}
        self.assertFalse(dep.starts(ign, "b", ["docs/development/x.md", "README.md"]))
        self.assertTrue(dep.starts(ign, "b", ["docs/development/x.md", "admin/go.mod"]))
        self.assertTrue(dep.starts({"push": None}, "b", ["x"]))
        self.assertFalse(dep.starts({"schedule": [{"cron": "x"}]}, "b", ["x"]))
        self.assertTrue(dep.starts(["push", "workflow_dispatch"], "b", ["x"]))
        self.assertFalse(dep.starts({"push": {"branches": ["main"]}}, "dependabot/x", ["x"]))

    def test_needed_main(self):
        wf = {dep.SELF: {"pull_request": None}, ".github/workflows/release.yml": {"push": {"branches": ["**"]}},
              ".github/workflows/docs.yml": {"push": None}}
        self.assertEqual(dep.needed(wf, "b", ["x"]), [".github/workflows/docs.yml", ".github/workflows/release.yml"])
        self.assertEqual(dep.needed(wf, "main", ["x"], main=True), [".github/workflows/docs.yml"])


class Verdict(unittest.TestCase):
    def run_(self, path, status="completed", conclusion="success", event="push", created="2026-11-09T06:00:00Z", id_=1):
        return {"id": id_, "name": path, "path": path, "status": status, "conclusion": conclusion,
                "event": event, "created_at": created, "html_url": "u"}

    def test_states(self):
        a, b = ".github/workflows/admin.yml", ".github/workflows/docs.yml"
        self.assertEqual(dep.verdict([self.run_(a), self.run_(b)], [a, b])[0], "passed")
        self.assertEqual(dep.verdict([self.run_(a)], [a, b]), ("pending", {"pending": [], "missing": [b]}))
        self.assertEqual(dep.verdict([self.run_(a, status="in_progress"), self.run_(b)], [a, b])[0], "pending")
        self.assertEqual(dep.verdict([self.run_(a, conclusion="failure"), self.run_(b)], [a, b])[0], "failed")
        self.assertEqual(dep.verdict([self.run_(a, conclusion="cancelled"), self.run_(b)], [a, b])[0], "failed")
        # the gate's own runs and Dependabot's update jobs do not count
        runs = [self.run_(a), self.run_(dep.SELF, status="in_progress", event="pull_request"),
                self.run_("dynamic/dependabot/dependabot-updates", status="in_progress", event="dynamic")]
        self.assertEqual(dep.verdict(runs, [a])[0], "passed")
        # a run started by hand next to a push run: each counts
        runs = [self.run_(a), self.run_(b, event="workflow_dispatch", conclusion="failure")]
        self.assertEqual(dep.verdict(runs, [a, b])[0], "failed")
        # the newest of the same workflow and event
        runs = [self.run_(a, conclusion="failure", id_=1), self.run_(a, created="2026-11-09T07:00:00Z", id_=2)]
        self.assertEqual(dep.verdict(runs, [a])[0], "passed")


@unittest.skipUnless(shutil.which("yq"), "yq not installed")
class ThisRepository(unittest.TestCase):
    def setUp(self):
        self.cwd = os.getcwd()
        os.chdir(ROOT)
        self.wf = dep.load_workflows()

    def tearDown(self):
        os.chdir(self.cwd)

    def names(self, branch, files, main=False):
        return [Path(p).stem for p in dep.needed(self.wf, branch, files, main)]

    def test_go_modules(self):
        self.assertEqual(self.names("dependabot/go_modules/admin/x", ["admin/go.mod", "admin/go.sum"]),
                         ["admin", "docs", "helm", "release", "syncstorage-rs"])
        self.assertEqual(self.names("main", ["admin/go.mod"], main=True), ["admin", "docs", "helm", "syncstorage-rs"])

    def test_actions(self):
        self.assertEqual(self.names("main", [".github/workflows/fxa.yml"], main=True), ["docs", "fxa", "syncstorage-rs"])
        self.assertEqual(self.names("main", ["docs/requirements.txt"], main=True), ["docs"])

    def test_every_needed_workflow_can_be_started_by_hand(self):
        for path, on in self.wf.items():
            if path != dep.SELF and dep.push_filter(on) is not None:
                self.assertTrue(dep.dispatchable(on), path)


if __name__ == "__main__":
    unittest.main()
