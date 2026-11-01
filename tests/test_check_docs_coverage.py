#!/usr/bin/env python3
"""Self-test of tests/check_docs_coverage.py on fixtures: python3 -I tests/test_check_docs_coverage.py"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("coverage", Path(__file__).resolve().parent / "check_docs_coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


def run(files, check):
    with tempfile.TemporaryDirectory() as root:
        for name, text in files.items():
            p = Path(root) / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
        c = coverage.Coverage(root)
        getattr(c, check)()
        return c.errors


VALUES = """\
# a comment: key: not a value
image:
  repository: ghcr.io/x
  tag: latest
fxa:
  enabled: false
  resources:
    auth:
      requests:
        memory: 1Gi
  ingress:
    className: ""
    tls:
      enabled: false
      secretNames:
        content: ""
        auth: ""
  notify:
    - url: "ntfy://x"
      name: one
  persistence:
    size: 1Gi
    storageClass: ""
syncstorage:
  resources: {}
    # limits:
    #   cpu: 1000m
nodeSelector: {}
"""


class Values(unittest.TestCase):
    def test_keys(self):
        keys = coverage.yaml_keys(VALUES)
        self.assertIn(("fxa.resources.auth.requests.memory", 10, False), keys)
        self.assertIn(("fxa.ingress", 11, True), keys)
        self.assertIn(("fxa.notify", 18, False), keys)
        self.assertFalse(any(p.startswith("fxa.notify.") or p.endswith(".url") for p, _, _ in keys))
        self.assertFalse(any("limits" in p or "comment" in p for p, _, _ in keys))

    def test_covered(self):
        settings = ("| `image.repository`, `.tag` | x |\n"
                    "| `fxa.enabled` and `fxa.resources` | x |\n"
                    "| `fxa.ingress.className`, `.tls.enabled`, `.tls.secretNames.content`, `.auth` | x |\n"
                    "| `fxa.notify` | `fxa.persistence.*` |\n"
                    "```yaml\n`syncstorage.resources`\n```\n"
                    "`nodeSelector`\n")
        errors = run({"charts/firefox-sync/values.yaml": VALUES, "docs/reference/settings.md": settings}, "check_values")
        # fxa.resources is passed as it is (PASS_THROUGH): its own path covers its keys;
        # syncstorage.resources only in a fence
        self.assertEqual(errors, ["charts/firefox-sync/values.yaml:25: syncstorage.resources is not in docs/reference/settings.md"])

    def test_pass_through(self):
        settings = "`fxa.resources.auth.requests.memory` `syncstorage.resources` `fxa.enabled` `image.*`\n"
        files = {"charts/firefox-sync/values.yaml": "fxa:\n  enabled: true\n  db:\n    resources:\n      requests:\n        memory: 1Gi\n"
                                                    "syncstorage:\n  resources:\n    limits:\n      cpu: 1\n"
                                                    "image:\n  tag: x\n",
                 "docs/reference/settings.md": settings}
        errors = run(files, "check_values")
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("fxa.db.resources.requests.memory", errors[0])

    def test_unknown_relative_span_is_skipped(self):
        files = {"charts/firefox-sync/values.yaml": "a:\n  b: 1\n  c: 2\n",
                 "docs/reference/settings.md": "`a.b`, `.nope`, `.c`\n"}
        self.assertEqual(run(files, "check_values"), [])


MONITORING = """\
# Monitoring
## Setup checks
- **Sync node**: x
- **Sign-in keys** (`FXA_OAUTH_SERVER_URL`): y
## Event log
| `admin` | x |
| `sign-up`, `new device` | y |
## Prometheus
| `ffs_up{component}` | x |
| `ffs_sync_accounts`, `ffs_sync_full` | y |
## After
`ffs_late` `health`
"""

GO = """\
package main
const oauthKeysCheck = "Sign-in keys (FXA_OAUTH_SERVER_URL)"
var eventKinds = []string{"admin", "health"}
var alertKinds = map[string]bool{"admin": true,
	"health": true}
func f() {
	gauge("ffs_sync_accounts", "x", 1)
	gauge("ffs_late", "x", 1)
	b.WriteString("# HELP ffs_up x\\n# TYPE ffs_up gauge\\n")
	h.app.event("attention", "x")
	h.app.alert("sign-up refused", "x")
	events = append(events, Event{At: ms(at), Kind: "sign-up", Detail: email})
	_ = setupCheck{Name: "Sync node"}
	_ = setupCheck{Name: oauthKeysCheck, OK: true}
	_ = setupCheck{Name: "Old setting names (.env)"}
}
"""


class Admin(unittest.TestCase):
    files = {"docs/admin/monitoring.md": MONITORING, "admin/web.go": GO,
             "admin/web_test.go": 'gauge("ffs_test_only", "x", 1)\n',
             "docs/admin/alerts.md": "# Alerts\n## Webhook schema\n| `kind` | `admin`, `health`, `sign-up refused` |\n## Other\n`sign-up`\n"}

    def test_metrics(self):
        errors = run(self.files, "check_metrics")
        self.assertEqual(errors, ["admin/web.go:8: metric ffs_late is not in docs/admin/monitoring.md#prometheus"])

    def test_events(self):
        errors = run(self.files, "check_events")
        # health only after the section; attention from a call, sign-up from a literal: documented
        self.assertEqual(len(errors), 2, errors)
        self.assertTrue(errors[0].startswith("admin/web.go:3: event kind health is not"), errors)
        self.assertTrue(errors[1].startswith("admin/web.go:10: event kind attention is not"), errors)

    def test_alerts(self):
        errors = run(self.files, "check_alerts")
        self.assertEqual(errors, ["admin/web.go:12: alert kind sign-up is not in docs/admin/alerts.md#webhook-schema"])

    def test_setup(self):
        errors = run(self.files, "check_setup")
        self.assertEqual(errors, ["admin/web.go:15: setup check Old setting names is not in docs/admin/monitoring.md#setup-checks"])

    def test_missing_section(self):
        files = dict(self.files, **{"docs/admin/monitoring.md": "# Monitoring\n"})
        errors = run(files, "check_metrics")
        self.assertEqual(errors, ["docs/admin/monitoring.md:0: no heading for #prometheus"])


class Sections(unittest.TestCase):
    def test_section(self):
        text = "# T\n## A\na\n### A.1\nb\n```\n## not a heading\n```\n## B\nc\n"
        self.assertEqual(coverage.section(text, "a"), ["a", "### A.1", "b"])
        self.assertEqual(coverage.section(text, "b"), ["c"])
        self.assertIsNone(coverage.section(text, "not-a-heading"))


if __name__ == "__main__":
    unittest.main()
