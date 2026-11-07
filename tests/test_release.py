#!/usr/bin/env python3
"""Self-test of .github/scripts/release.py, the release decision, its notes and the rewriting of
CHANGELOG.md, without the network: python3 -I tests/test_release.py"""

import contextlib
import datetime
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).resolve().parent.parent / ".github/scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

STATE = {"syncstorage-rs": "0.24.0", "fxa": "v1.349.0", "channelserver": "0.9.3",
         "patches": {"syncstorage-rs": "mozilla-services/syncstorage-rs#2638@aaa..bbb", "fxa": "none"}}

EMPTY = """# Changelog

Intro.

## Unreleased

### Breaking

### Added

### Changed

### Fixed

### Security

## v2026.11.02 — 2026-11-02

### Added

- An older entry.
"""

FILLED = EMPTY.replace("### Added\n\n### Changed", "### Added\n\n- A QR code for phones.\n- A user.js download,\n  for computers.\n\n### Changed", 1).replace(
    "### Fixed\n\n### Security", "### Fixed\n\n<!-- one line per fix -->\n- The pool's keep-alive.\n\n### Security", 1)


def state(**changes):
    s = json.loads(json.dumps(STATE))
    for k, v in changes.items():
        if k.startswith("patches_"):
            s["patches"][k[len("patches_"):]] = v
        else:
            s[k] = v
    return s


class Decision(unittest.TestCase):
    def test_nothing_new(self):
        go, why = release.decide("schedule", "v2026.11.02", STATE, state(), release.unreleased_entries(EMPTY))
        self.assertFalse(go)
        self.assertIn("nothing new since v2026.11.02", why)
        self.assertFalse(release.decide("manual", "v2026.11.02", STATE, state(), [])[0])

    def test_new_syncstorage_rs(self):
        go, why = release.decide("schedule", "v2026.11.02", STATE, state(**{"syncstorage-rs": "0.24.1"}), [])
        self.assertTrue(go)
        self.assertEqual(why, "syncstorage-rs 0.24.0 -> 0.24.1")

    def test_new_fxa(self):
        go, why = release.decide("schedule", "v2026.11.02", STATE, state(fxa="v1.350.0"), [])
        self.assertTrue(go)
        self.assertIn("accounts (mozilla/fxa) v1.349.0 -> v1.350.0", why)

    def test_new_pairing_server_and_patches(self):
        self.assertTrue(release.decide("schedule", "v2026.11.02", STATE, state(channelserver="0.9.4"), [])[0])
        go, why = release.decide("schedule", "v2026.11.02", STATE, state(patches_fxa="mozilla/fxa#21709@c..d"), [])
        self.assertTrue(go)
        self.assertIn("the upstream patches of fxa: none -> mozilla/fxa#21709@c..d", why)

    def test_unreleased_entries(self):
        go, why = release.decide("schedule", "v2026.11.02", STATE, state(), release.unreleased_entries(FILLED))
        self.assertTrue(go)
        self.assertEqual(why, "CHANGELOG.md's Unreleased has 3 entries")

    def test_tag_push(self):
        self.assertEqual(release.decide("tag", "v2026.11.02", STATE, state(), []), (True, "a tag was pushed"))

    def test_first_release(self):
        self.assertTrue(release.decide("schedule", None, None, state(), [])[0])
        self.assertTrue(release.decide("schedule", "v2026.11.02", None, state(), [])[0])

    def test_previous_release(self):
        body = lambda s: f"notes\n<!-- release-state: {json.dumps(s)} -->\n"
        releases = [
            {"tag_name": "syncstorage-rs-mysql-0.24.0-20261102T155449", "body": ""},
            {"tag_name": "v2026.11.02", "body": body(STATE)},
            {"tag_name": "v2026.11.02.2", "body": body(state(fxa="v1.350.0"))},
            {"tag_name": "v2026.11.09", "body": body(STATE), "draft": True},
            {"tag_name": "v2026.10.26", "body": ""},
        ]
        self.assertEqual(release.previous_release(releases), ("v2026.11.02.2", state(fxa="v1.350.0")))
        self.assertEqual(release.previous_release(releases[:1]), (None, None))

    def test_tags(self):
        day = datetime.date(2026, 11, 9)
        self.assertEqual(release.next_tag(day, []), "v2026.11.09")
        self.assertEqual(release.next_tag(day, ["v2026.11.09"]), "v2026.11.09.2")
        self.assertEqual(release.next_tag(day, ["v2026.11.09", "v2026.11.09.2"]), "v2026.11.09.3")
        for t in ("v2026.11.09", "v2026.11.09.2"):
            self.assertTrue(release.TAG.match(t), t)
        for t in ("v2026.11.9", "2026.11.09", "v1.2.3", "chart-v0.2.0", "v2026.11.09-rc1"):
            self.assertFalse(release.TAG.match(t), t)
        self.assertEqual(release.title("v2026.11.09", STATE), "v2026.11.09 — syncstorage-rs 0.24.0, accounts v1.349.0")


class Changelog(unittest.TestCase):
    def test_entries(self):
        self.assertFalse(release.has_entries(release.unreleased_entries(EMPTY)))
        self.assertEqual(release.unreleased_entries(FILLED), [
            ("Breaking", []), ("Added", ["- A QR code for phones.", "- A user.js download,\n  for computers."]),
            ("Changed", []), ("Fixed", ["- The pool's keep-alive."]), ("Security", [])])
        self.assertEqual(release.unreleased_entries("# Changelog\n"), [])
        self.assertEqual(release.unreleased_entries(None), [])

    def test_move_unreleased(self):
        new = release.release_changelog(FILLED, "v2026.11.09", "2026-11-09")
        self.assertEqual(new, """# Changelog

Intro.

## Unreleased

### Breaking

### Added

### Changed

### Fixed

### Security

## v2026.11.09 — 2026-11-09

### Added

- A QR code for phones.
- A user.js download,
  for computers.

### Fixed

- The pool's keep-alive.

## v2026.11.02 — 2026-11-02

### Added

- An older entry.
""")
        self.assertFalse(release.has_entries(release.unreleased_entries(new)))

    def test_idempotent(self):
        once = release.release_changelog(FILLED, "v2026.11.09", "2026-11-09")
        self.assertEqual(release.release_changelog(once, "v2026.11.09", "2026-11-09"), once)
        self.assertEqual(release.release_changelog(EMPTY, "v2026.11.02", "2026-11-02"), EMPTY)

    def test_upstream_only(self):
        new = release.release_changelog(EMPTY, "v2026.11.09", "2026-11-09", upstream="Upstream only: x.")
        self.assertIn("### Security\n\n## v2026.11.09 — 2026-11-09\n\nUpstream only: x.\n\n## v2026.11.02", new)

    def test_entries_added_after_the_release_stay(self):
        released = release.unreleased_entries(FILLED)
        later = FILLED.replace("### Changed\n", "### Changed\n\n- Added after the build.\n", 1)
        new = release.release_changelog(later, "v2026.11.09", "2026-11-09", released)
        left = release.unreleased_entries(new)
        self.assertEqual([e for _, es in left for e in es], ["- Added after the build."])
        self.assertIn("- The pool's keep-alive.", new.split("## v2026.11.09")[1])

    def test_no_unreleased(self):
        self.assertEqual(release.release_changelog("# Changelog\n", "v2026.11.09", "2026-11-09"), "# Changelog\n")

    def test_added_entries(self):
        self.assertEqual(release.added_entries(EMPTY, FILLED)[0], "- A QR code for phones.")
        self.assertEqual(release.added_entries(FILLED, FILLED), [])
        self.assertEqual(release.added_entries(None, EMPTY), [])

    def test_repository_file(self):
        # this repository's CHANGELOG.md: the format the release expects
        text = (Path(__file__).resolve().parent.parent / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Changelog\n"))
        self.assertEqual([h for h, _ in release.unreleased_entries(text)], list(release.SUBSECTIONS))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "CHANGELOG.md"
            p.write_text(FILLED, encoding="utf-8")
            r = Path(d) / "unreleased.md"
            r.write_text(release.render_sections(release.unreleased_entries(FILLED)), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                release.main(["changelog", "--version", "v2026.11.09", "--date", "2026-11-09", "--released", str(r), str(p)])
            self.assertEqual(p.read_text(encoding="utf-8"), release.release_changelog(FILLED, "v2026.11.09", "2026-11-09"))


class Notes(unittest.TestCase):
    TAGS = "\n".join(f"x\trefs/tags/{t}" for t in ("0.23.3", "0.24.0", "0.24.1", "0.24.1^{}", "v1.348.5",
                                                     "v1.349.0", "v1.349.1", "v1.350.0", "0.9.3"))

    def current(self, s):
        return {"state": s, "images": [
            {"tag": "syncstorage-rs-mysql-0.24.1", "dated": "syncstorage-rs-mysql-0.24.1-20261109T061500", "digest": "sha256:1"},
            {"tag": "admin-latest", "dated": None, "digest": "sha256:2"}]}

    def test_notes(self):
        new = state(**{"syncstorage-rs": "0.24.1", "fxa": "v1.350.0"})
        text = release.notes("v2026.11.09", release.unreleased_entries(FILLED), "v2026.11.02", STATE,
                             self.current(new), ("0.2.0", ["0.1.0", "0.2.0"]), "ghcr.io", "Owner/Repo",
                             ls_remote=lambda url: self.TAGS)
        self.assertTrue(text.startswith("## Changes\n\n### Added\n\n- A QR code for phones.\n"), text)
        self.assertIn("## Upstream\n\nSince [v2026.11.02](https://github.com/Owner/Repo/releases/tag/v2026.11.02):", text)
        self.assertIn("- syncstorage-rs **0.24.1** (was 0.24.0): releases [0.24.1](https://github.com/mozilla-services/syncstorage-rs/releases/tag/0.24.1)"
                      "; [changes 0.24.0...0.24.1](https://github.com/mozilla-services/syncstorage-rs/compare/0.24.0...0.24.1)"
                      "; [CHANGELOG.md](https://github.com/mozilla-services/syncstorage-rs/blob/0.24.1/CHANGELOG.md)", text)
        self.assertIn("releases [v1.349.1](https://github.com/mozilla/fxa/releases/tag/v1.349.1), [v1.350.0]", text)
        self.assertIn("- pairing server (mozilla-services/channelserver) **0.9.3**, unchanged", text)
        self.assertIn("| `syncstorage-rs-mysql-0.24.1` | `syncstorage-rs-mysql-0.24.1-20261109T061500` | `sha256:1` |", text)
        self.assertIn("`oci://ghcr.io/owner/repo/charts/firefox-sync` version `0.2.0`", text)
        self.assertEqual(release.previous_release([{"tag_name": "v2026.11.09", "body": text}])[1], new)

    def test_notes_without_entries_or_previous(self):
        text = release.notes("v2026.11.09", release.unreleased_entries(EMPTY), None, None, self.current(STATE),
                             ("0.3.0", ["0.2.0"]), "ghcr.io", "owner/repo", ls_remote=lambda url: self.TAGS)
        self.assertTrue(text.startswith("## Upstream\n\n- syncstorage-rs **0.24.0**: releases [0.24.0]"), text)
        self.assertIn("The chart of this commit (0.3.0) is not published; the newest published is `0.2.0`", text)

    def test_published(self):
        class Fake:
            repository = "owner/repo"

            def tags(self, name=None):
                return ["syncstorage-rs-mysql-0.23.3", "syncstorage-rs-mysql-0.24.0", "syncstorage-rs-mysql-latest",
                        "syncstorage-rs-mysql-0.24.0-20261026T130431", "syncstorage-rs-mysql-0.24.0-20261102T155449",
                        "syncstorage-rs-mysql-0.24.0-20261102T155449-linux-amd64", "syncstorage-rs-mysql-0.24.0-linux-amd64",
                        "fxa-mono-v1.348.5", "fxa-mono-v1.349.0", "fxa-mono-v1.349.0-linux-amd64-run1",
                        "fxa-channelserver-0.9.3", "admin-latest"]

            def labels(self, tag):
                return {"org.firefox-sync.upstream-patches": "p-" + tag}

            def digest(self, tag):
                return "sha256:" + tag

        out = release.published(Fake())
        self.assertEqual(out["state"], {"syncstorage-rs": "0.24.0", "fxa": "v1.349.0", "channelserver": "0.9.3",
                                        "patches": {"syncstorage-rs": "p-syncstorage-rs-mysql-0.24.0", "fxa": "p-fxa-mono-v1.349.0"}})
        self.assertEqual(out["images"][0], {"tag": "syncstorage-rs-mysql-0.24.0",
                                            "dated": "syncstorage-rs-mysql-0.24.0-20261102T155449",
                                            "digest": "sha256:syncstorage-rs-mysql-0.24.0"})
        self.assertEqual([i["tag"] for i in out["images"]],
                         ["syncstorage-rs-mysql-0.24.0", "fxa-mono-v1.349.0", "fxa-channelserver-0.9.3", "admin-latest"])


class Weekly(unittest.TestCase):
    class GH:
        def __init__(self, runs):
            self.runs = runs

        def latest_run(self, workflow, event):
            return self.runs.get(workflow)

    NOW = datetime.datetime(2026, 11, 9, 9, 0, tzinfo=datetime.timezone.utc)

    def run_(self, status="completed", created="2026-11-09T06:15:00Z", sha="abc"):
        return {"status": status, "created_at": created, "head_sha": sha, "html_url": "u"}

    def test_both_done(self):
        gh = self.GH({"syncstorage-rs.yml": self.run_(sha="s1"), "fxa.yml": self.run_(sha="f1")})
        self.assertEqual(release.weekly_target(gh, self.NOW), ("s1", None))

    def test_one_running_or_old(self):
        gh = self.GH({"syncstorage-rs.yml": self.run_(), "fxa.yml": self.run_(status="in_progress")})
        self.assertIn("waiting for the scheduled run of fxa.yml", release.weekly_target(gh, self.NOW)[1])
        gh = self.GH({"syncstorage-rs.yml": self.run_(), "fxa.yml": self.run_(created="2026-11-02T06:45:00Z")})
        self.assertIn("waiting for this week's scheduled run of fxa.yml", release.weekly_target(gh, self.NOW)[1])


class WaitForCI(unittest.TestCase):
    class GH:
        def __init__(self, runs):
            self.runs = runs

        def runs_of(self, sha):
            return self.runs

    def run_(self, event="push", branch="main", conclusion="success", path=".github/workflows/docs.yml"):
        return {"id": 1, "name": path, "path": path, "event": event, "head_branch": branch,
                "status": "completed", "conclusion": conclusion, "created_at": "2026-11-09T06:15:00Z"}

    def test_push_or_dispatch_on_main(self):
        self.assertIsNone(release.wait_for_ci(self.GH([self.run_()]), "a" * 40, 0, 60))
        # a merge of the dependencies workflow: main's CI started by hand (workflow_dispatch)
        self.assertIsNone(release.wait_for_ci(self.GH([self.run_(event="workflow_dispatch")]), "a" * 40, 0, 60))

    def test_no_run_on_main_or_failed(self):
        why = release.wait_for_ci(self.GH([self.run_(branch="dependabot/x")]), "a" * 40, 0, 60)
        self.assertIn("no CI run of", why)
        why = release.wait_for_ci(self.GH([self.run_(conclusion="failure")]), "a" * 40, 0, 60)
        self.assertIn("did not pass", why)


if __name__ == "__main__":
    unittest.main()
