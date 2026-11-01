#!/usr/bin/env python3
"""Check that the features of the stack are in the docs.

Usage: python3 -I tests/check_docs_coverage.py [--root DIR]

- Helm values: every key of charts/firefox-sync/values.yaml, at every depth, appears in
  docs/reference/settings.md as its dotted path in a code span (`fxa.signupAllowlist`).
  A span that starts with a dot continues the path before it on the same line, at the
  first level where that key exists (`database.persistence.size`, `.storageClass`;
  `fxa.ingress.tls.enabled`, `.tls.secretNames.content`, `.auth`). `path.*` covers
  everything under path. A map is covered by its keys, and a value the chart hands to
  Kubernetes as it is (resources, annotations, selectors: PASS_THROUGH) by its own path.
  The items of a list are not values of their own.
- Prometheus metrics: every metric the admin UI serves (# TYPE ffs_... and gauge("ffs_...")
  in admin/*.go but the tests) is in a code span of docs/admin/monitoring.md#prometheus.
- Event kinds: those of the Activity page's filter (eventKinds) and every kind an event is
  written with (event("kind", ...), Event{Kind: "kind"}) are in a code span of
  docs/admin/monitoring.md#event-log.
- Alert kinds: those of alertKinds, of alert("kind", ...), of the events of the accounts
  database (Event{Kind: "kind"}: health.go alerts them all) and of Alert{Kind: "kind"} (the
  test notification) are in a code span of docs/admin/alerts.md#webhook-schema, which
  lists the kinds a destination gets.
- Setup checks: the name of every setupCheck{Name: ...} (and c.Name = "...") of admin/*.go,
  up to its " (", is in bold in docs/admin/monitoring.md#setup-checks (**Sync node**).

Prints one line per gap, file:line: what is not in which page, and exits 1 when there is
any. Stdlib only.
"""

import argparse
import importlib.util
import re
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("check_markdown_links", Path(__file__).resolve().parent / "check_markdown_links.py")
links = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(links)

SETTINGS = "docs/reference/settings.md"
VALUES = "charts/firefox-sync/values.yaml"
MONITORING = "docs/admin/monitoring.md"
ALERTS = "docs/admin/alerts.md"

# values the templates pass to Kubernetes as they are (toYaml): their keys are Kubernetes'
# fields, not the chart's
PASS_THROUGH = {"resources", "initResources", "annotations", "podAnnotations", "nodeSelector",
                "tolerations", "affinity", "imagePullSecrets", "namespaceSelector", "podSelector",
                "extraFrom"}

YAML_KEY = re.compile(r"^([A-Za-z_][\w-]*)\s*:(?:\s|$)")
PATH = re.compile(r"^[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*(\.\*)?$")
REL_PATH = re.compile(r"^(?:\.[A-Za-z_][\w-]*)+(\.\*)?$")

METRIC = [re.compile(r"# TYPE (ffs_\w+)"), re.compile(r"\bgauge\(\s*\"(ffs_\w+)\"")]
EVENT_CALL = re.compile(r"\b(?:event|Event|EventWritten)\(\s*\"([^\"]+)\"")
EVENT_LITERAL = re.compile(r"(?<![\w])Event\{[^}]*?\bKind:\s*\"([^\"]+)\"")
ALERT_CALL = re.compile(r"\balert\(\s*\"([^\"]+)\"")
ALERT_LITERAL = re.compile(r"(?<![\w])Alert\{[^}]*?\bKind:\s*\"([^\"]+)\"")
CHECK_NAME = re.compile(r"setupCheck\{Name:\s*(?:\"([^\"]+)\"|(\w+))|\bc\.Name\s*=\s*\"([^\"]+)\"")
CONST = re.compile(r"^\s*(?:const\s+)?(\w+)\s*=\s*\"([^\"]*)\"", re.M)


def yaml_keys(text):
    """The keys of a values.yaml: (dotted path, line, has children), list items skipped."""
    out = []
    stack = []  # (indent, key)
    skip = None  # the indent of a list item whose lines are skipped
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if skip is not None and indent > skip:
            continue
        skip = None
        if s.startswith("- ") or s == "-":
            skip = indent
            continue
        m = YAML_KEY.match(s)
        if not m:
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = ".".join([k for _, k in stack] + [m.group(1)])
        if out and out[-1][3] < indent and path.startswith(out[-1][0] + "."):
            out[-1] = out[-1][:2] + (True, out[-1][3])
        out.append((path, n, False, indent))
        stack.append((indent, m.group(1)))
    return [(p, n, children) for p, n, children, _ in out]


def code_spans(line):
    return [m.group(2).strip() for m in links.CODE_SPAN.finditer(line)]


def unfenced(text):
    """(line number, line) of a markdown text outside its fences."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        m = links.FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        yield n, line


def section(text, anchor):
    """The lines under the heading of anchor, up to the next heading of its level or higher,
    or None when there is no such heading."""
    out, level, seen = None, 0, {}
    for _, line in unfenced(text):
        h = links.HEADING.match(line)
        if h:
            base = links.slug(h.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            if out is not None and len(h.group(1)) <= level:
                return out
            if out is None and (base if count == 0 else f"{base}-{count}") == anchor:
                out, level = [], len(h.group(1))
                continue
        if out is not None:
            out.append(line)
    return out


def documented_paths(text, known):
    """The values a settings page names: exact paths, and wildcards (path.*)."""
    exact, wild = set(), set()
    for _, line in unfenced(text):
        prev = None
        for span in code_spans(line):
            if PATH.match(span):
                path = span[:-2] if span.endswith(".*") else span
                if path not in known:
                    prev = None
                    continue
            elif REL_PATH.match(span) and prev:
                rel = span[:-2] if span.endswith(".*") else span
                parts = prev.split(".")[:-1]
                path = None
                while parts:
                    if ".".join(parts) + rel in known:
                        path = ".".join(parts) + rel
                        break
                    parts.pop()
                if path is None:
                    continue
            else:
                continue
            (wild if span.endswith(".*") else exact).add(path)
            prev = path
    return exact, wild


class Coverage:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.errors = []

    def error(self, where, line, msg):
        self.errors.append(f"{where}:{line}: {msg}")

    def read(self, rel):
        p = self.root / rel
        return p.read_text(encoding="utf-8") if p.is_file() else None

    def page_section(self, page, anchor):
        text = self.read(page)
        if text is None:
            self.error(page, 0, "does not exist")
            return None
        lines = section(text, anchor)
        if lines is None:
            self.error(page, 0, f"no heading for #{anchor}")
        return lines

    def go_files(self):
        admin = self.root / "admin"
        if not admin.is_dir():
            return []
        return sorted(p for p in admin.glob("*.go") if not p.name.endswith("_test.go"))

    def go_matches(self, patterns):
        """name -> (file, line) of its first match in admin/*.go, in file order."""
        found = {}
        for p in self.go_files():
            text = p.read_text(encoding="utf-8")
            for pattern in patterns:
                for m in pattern.finditer(text):
                    name = next(g for g in m.groups() if g is not None)
                    line = text.count("\n", 0, m.start()) + 1
                    found.setdefault(name, (f"admin/{p.name}", line))
        return dict(sorted(found.items(), key=lambda kv: (kv[1][0], kv[1][1])))

    def go_list(self, var):
        """The strings of var = []string{...} or var = map[string]bool{...}: name -> (file, line)."""
        decl = re.compile(r"\b" + re.escape(var) + r"\s*=\s*(?:\[\]string|map\[string\]bool)\{(.*?)\n?\}\s*$", re.S | re.M)
        found = {}
        for p in self.go_files():
            text = p.read_text(encoding="utf-8")
            m = decl.search(text)
            if not m:
                continue
            for s in re.finditer(r"\"([^\"]+)\"", m.group(1)):
                found.setdefault(s.group(1), (f"admin/{p.name}", text.count("\n", 0, m.start(1) + s.start()) + 1))
        return found

    def check_values(self):
        values, settings = self.read(VALUES), self.read(SETTINGS)
        if values is None:
            return
        if settings is None:
            self.error(SETTINGS, 0, "does not exist")
            return
        keys = yaml_keys(values)
        known = {p for p, _, _ in keys}
        exact, wild = documented_paths(settings, known)
        for path, line, children in keys:
            if children:
                continue  # a map: covered by its keys
            parts = path.split(".")
            covered = path in exact or any(
                ".".join(parts[:i]) in wild or (parts[i - 1] in PASS_THROUGH and ".".join(parts[:i]) in exact)
                for i in range(1, len(parts)))
            if not covered:
                self.error(VALUES, line, f"{path} is not in {SETTINGS}")

    def spans_of(self, page, anchor):
        lines = self.page_section(page, anchor)
        if lines is None:
            return None
        return [s for line in lines for s in code_spans(line)]

    def check_metrics(self):
        spans = self.spans_of(MONITORING, "prometheus")
        if spans is None:
            return
        named = {m.group(0) for s in spans for m in [re.match(r"ffs_\w+", s)] if m}
        for name, (where, line) in self.go_matches(METRIC).items():
            if name not in named:
                self.error(where, line, f"metric {name} is not in {MONITORING}#prometheus")

    def check_events(self):
        spans = self.spans_of(MONITORING, "event-log")
        if spans is None:
            return
        kinds = self.go_list("eventKinds")
        for k, v in self.go_matches([EVENT_CALL, EVENT_LITERAL]).items():
            kinds.setdefault(k, v)
        for kind, (where, line) in kinds.items():
            if kind not in spans:
                self.error(where, line, f"event kind {kind} is not in {MONITORING}#event-log")

    def check_alerts(self):
        spans = self.spans_of(ALERTS, "webhook-schema")
        if spans is None:
            return
        kinds = self.go_list("alertKinds")
        for k, v in self.go_matches([ALERT_CALL, EVENT_LITERAL, ALERT_LITERAL]).items():
            kinds.setdefault(k, v)
        for kind, (where, line) in kinds.items():
            if kind not in spans:
                self.error(where, line, f"alert kind {kind} is not in {ALERTS}#webhook-schema")

    def check_setup(self):
        lines = self.page_section(MONITORING, "setup-checks")
        if lines is None:
            return
        bold = set(re.findall(r"\*\*(.+?)\*\*", "\n".join(lines)))
        consts = {}
        for p in self.go_files():
            for m in CONST.finditer(p.read_text(encoding="utf-8")):
                consts.setdefault(m.group(1), m.group(2))
        seen = set()
        for p in self.go_files():
            text = p.read_text(encoding="utf-8")
            for m in CHECK_NAME.finditer(text):
                full = m.group(1) or m.group(3) or consts.get(m.group(2) or "")
                if not full:
                    continue
                name = full.split(" (", 1)[0]
                if name in seen:
                    continue
                seen.add(name)
                if name not in bold:
                    self.error(f"admin/{p.name}", text.count("\n", 0, m.start()) + 1,
                               f"setup check {name} is not in {MONITORING}#setup-checks")

    def check_all(self):
        self.check_values()
        self.check_metrics()
        self.check_events()
        self.check_alerts()
        self.check_setup()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--root", default=Path(__file__).resolve().parent.parent, help="the repository (default: this one)")
    args = p.parse_args(argv)
    c = Coverage(args.root)
    c.check_all()
    for e in c.errors:
        print(e)
    print(f"{len(c.errors)} gap(s) in the docs", file=sys.stderr)
    return 1 if c.errors else 0


if __name__ == "__main__":
    sys.exit(main())
