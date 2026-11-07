#!/usr/bin/env python3
"""The releases of this repository: when one is cut, its notes, and CHANGELOG.md.

Usage:
  release.py plan --event tag|schedule|manual [--tag vYYYY.MM.DD[.N]] [--target SHA]
                  [--output DIR] [--dry-run]
  release.py changelog --version vYYYY.MM.DD[.N] --date YYYY-MM-DD [--released FILE]
                  [--upstream TEXT] CHANGELOG.md

plan decides whether there is a release (docs/development/releasing.md#releases):
  tag       a tag vYYYY.MM.DD[.N] we pushed: always, once the CI of its commit passed
            (waits for the runs of that commit, fails if one failed)
  schedule  after the weekly runs of syncstorage-rs.yml and fxa.yml (both completed): only
            if what they publish changed since the previous release (the syncstorage-rs,
            accounts and pairing server versions of the images, the upstream patches applied
            to them) or CHANGELOG.md's Unreleased has entries. Otherwise no release, and why
  manual    as schedule, for the commit --target, without waiting for the weekly runs
With --output it writes there decision.json, notes.md (the release notes) and
unreleased.md (the Unreleased section released); in GitHub Actions it sets the step outputs
release, tag, target and title. --dry-run prints the same and never says release=true.

changelog moves the entries of Unreleased (those of --released, an unreleased.md of plan,
when given: entries added since the released commit stay) into a section
"## <version> — <date>" under it, drops the empty subsections there, and leaves Unreleased
with its subsection headings and nothing else. Idempotent: a version already in the file
changes nothing. Without entries the section has the --upstream line.

Environment: GITHUB_REPOSITORY (owner/name), GITHUB_TOKEN (the API and ghcr.io),
GITHUB_API_URL, GITHUB_SERVER_URL, REGISTRY (ghcr.io). Python stdlib and git only.
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TAG = re.compile(r"^v(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$")
UNRELEASED = re.compile(r"^## +Unreleased\s*$", re.I)
SECTION = re.compile(r"^## ")
SUBSECTION = re.compile(r"^### +(.+?)\s*$")
ITEM = re.compile(r"^(?:[-*+]|\d+[.)]) ")
STATE = re.compile(r"<!-- release-state: (\{.*?\}) -->", re.S)
SUBSECTIONS = ("Breaking", "Added", "Changed", "Fixed", "Security")

SYNC_UPSTREAM = "mozilla-services/syncstorage-rs"
FXA_UPSTREAM = "mozilla/fxa"
PAIRING_UPSTREAM = "mozilla-services/channelserver"
# the workflow files of the weekly runs: the release comes after both
WEEKLY = ("syncstorage-rs.yml", "fxa.yml")
PATCHES_LABEL = "org.firefox-sync.upstream-patches"
SYNC_IMAGES = ("syncstorage-rs-mysql", "syncstorage-rs-postgres", "syncstorage-rs-mysql-init",
               "syncstorage-rs-postgres-init")
CHART = "charts/firefox-sync"


# ---- CHANGELOG.md ---------------------------------------------------------------------------

def split_changelog(text):
    """(before, unreleased, after): the lines up to and with "## Unreleased", the lines of
    its section, the rest from the next "## ". unreleased is None without the heading."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if UNRELEASED.match(l)), None)
    if start is None:
        return text, None, ""
    end = next((i for i in range(start + 1, len(lines)) if SECTION.match(lines[i])), len(lines))
    return "".join(lines[:start + 1]), lines[start + 1:end], "".join(lines[end:])


def _strip_comments(lines):
    out, inside = [], False
    for line in lines:
        text = line
        if inside:
            if "-->" not in text:
                continue
            text, inside = text.split("-->", 1)[1], False
        while "<!--" in text:
            head, rest = text.split("<!--", 1)
            if "-->" in rest:
                text = head + rest.split("-->", 1)[1]
            else:
                text, inside = head, True
        out.append(text if text.strip() or not line.strip() else "")
    return out


def parse_section(lines):
    """[(heading or None, [entry, ...]), ...] in order: an entry is a list item with its
    continuation lines, or a paragraph; HTML comments (hints for the writers) are no entry."""
    sections = [(None, [])]
    entry, blank = None, False
    for line in _strip_comments(lines):
        line = line.rstrip("\n").rstrip()
        m = SUBSECTION.match(line)
        if m:
            sections.append((m.group(1), []))
            entry, blank = None, False
        elif not line.strip():
            blank = entry is not None
        elif entry is not None and (line[:1].isspace() or (not blank and not ITEM.match(line))):
            entry += [""] if blank else []
            entry.append(line)
            blank = False
        else:
            entry, blank = [line], False
            sections[-1][1].append(entry)
    result = [(heading, ["\n".join(e) for e in entries]) for heading, entries in sections]
    return result[1:] if result[0] == (None, []) else result


def unreleased_entries(text):
    """parse_section of Unreleased, [] without one."""
    _, body, _ = split_changelog(text or "")
    return parse_section(body) if body is not None else []


def has_entries(sections):
    return any(entries for _, entries in sections)


def render_sections(sections, level="###"):
    """The subsections that have entries, as markdown; "" when none has."""
    parts = []
    for heading, entries in sections:
        if not entries:
            continue
        block = "\n".join(entries) if all(ITEM.match(e) and "\n\n" not in e for e in entries) else "\n\n".join(entries)
        parts.append((f"{level} {heading}\n\n" if heading else "") + block + "\n")
    return "\n".join(parts)


def added_entries(base_text, head_text):
    """The entries of HEAD's Unreleased that base's has not: what a branch added."""
    before = {e for _, entries in unreleased_entries(base_text) for e in entries}
    return [e for _, entries in unreleased_entries(head_text) for e in entries if e not in before]


def release_changelog(text, version, date, released=None, upstream=""):
    """CHANGELOG.md with the entries of Unreleased (those also in the sections released, when
    given) moved into "## <version> — <date>" right under it. Unchanged when the version has
    a section already, or the file no Unreleased."""
    if re.search(r"^## +" + re.escape(version) + r"(\s|$)", text, re.M):
        return text
    before, body, after = split_changelog(text)
    if body is None:
        return text
    current = parse_section(body)
    keep = None
    if released is not None:
        keep = {e for _, entries in released for e in entries}
    moved, left = [], []
    for heading, entries in current:
        go = [e for e in entries if keep is None or e in keep]
        moved.append((heading, go))
        left.append((heading, [e for e in entries if e not in go]))
    headings = [h for h, _ in left]
    for h in SUBSECTIONS:
        if h not in headings:
            left.append((h, []))
    unreleased = ""
    for heading, entries in left:
        if heading is None and not entries:
            continue
        unreleased += "\n" + (f"### {heading}\n" if heading else "")
        if entries:
            unreleased += "\n" + render_sections([(None, entries)])
    content = render_sections(moved) or (upstream.strip() + "\n" if upstream.strip() else "")
    section = f"## {version} — {date}\n" + ("\n" + content if content else "")
    return before + unreleased + "\n" + section + ("\n" + after if after else "")


# ---- GitHub and the registry ----------------------------------------------------------------

class GitHub:
    def __init__(self, repository, token=None, api=None, server=None):
        self.repository = repository
        self.token = token
        self.api = (api or "https://api.github.com").rstrip("/")
        self.server = (server or "https://github.com").rstrip("/")

    def get(self, path, params=None):
        url = f"{self.api}/{path.lstrip('/')}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "X-GitHub-Api-Version": "2022-11-28"})
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)

    def releases(self):
        out = []
        for page in range(1, 11):
            batch = self.get(f"repos/{self.repository}/releases", {"per_page": 100, "page": page})
            out += batch
            if len(batch) < 100:
                break
        return out

    def tags(self, prefix):
        try:
            refs = self.get(f"repos/{self.repository}/git/matching-refs/tags/{prefix}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return []
            raise
        return [r["ref"][len("refs/tags/"):] for r in refs]

    def latest_run(self, workflow, event):
        runs = self.get(f"repos/{self.repository}/actions/workflows/{workflow}/runs",
                        {"event": event, "per_page": 1}).get("workflow_runs") or []
        return runs[0] if runs else None

    def runs_of(self, sha):
        return self.get(f"repos/{self.repository}/actions/runs",
                        {"head_sha": sha, "per_page": 100}).get("workflow_runs") or []


class Registry:
    """The tags, digests and labels of this repository's images (OCI distribution API)."""

    ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json",
                        "application/vnd.docker.distribution.manifest.list.v2+json",
                        "application/vnd.oci.image.manifest.v1+json",
                        "application/vnd.docker.distribution.manifest.v2+json"))

    def __init__(self, host, repository, token=None):
        self.host = host
        self.repository = repository.lower()
        self.token = token
        self._tags = {}
        self._anonymous = {}

    def _auth(self, name):
        if self.token:
            return "Bearer " + base64.b64encode(self.token.encode()).decode()
        if name not in self._anonymous:
            url = f"https://{self.host}/token?" + urllib.parse.urlencode(
                {"scope": f"repository:{name}:pull", "service": self.host})
            with urllib.request.urlopen(url, timeout=60) as r:
                self._anonymous[name] = "Bearer " + json.load(r)["token"]
        return self._anonymous[name]

    def _get(self, name, path, accept=None, method="GET"):
        req = urllib.request.Request(f"https://{self.host}/v2/{name}/{path}", method=method,
                                     headers={"Authorization": self._auth(name)})
        if accept:
            req.add_header("Accept", accept)
        return urllib.request.urlopen(req, timeout=60)

    def tags(self, name=None):
        name = name or self.repository
        if name not in self._tags:
            tags, path = [], "tags/list?n=1000"
            while path:
                with self._get(name, path) as r:
                    tags += json.load(r).get("tags") or []
                    link = r.headers.get("Link") or ""
                m = re.search(r"<([^>]+)>;\s*rel=\"next\"", link)
                path = m.group(1).split(f"/v2/{name}/", 1)[-1] if m else None
            self._tags[name] = tags
        return self._tags[name]

    def digest(self, tag):
        with self._get(self.repository, f"manifests/{tag}", self.ACCEPT, "HEAD") as r:
            return r.headers.get("Docker-Content-Digest")

    def labels(self, tag, platform=("linux", "amd64")):
        with self._get(self.repository, f"manifests/{tag}", self.ACCEPT) as r:
            manifest = json.load(r)
        if "manifests" in manifest:
            ref = next((m["digest"] for m in manifest["manifests"]
                        if (m.get("platform") or {}).get("os") == platform[0]
                        and (m.get("platform") or {}).get("architecture") == platform[1]), None)
            if not ref:
                return {}
            with self._get(self.repository, f"manifests/{ref}", self.ACCEPT) as r:
                manifest = json.load(r)
        with self._get(self.repository, f"blobs/{manifest['config']['digest']}") as r:
            return (json.load(r).get("config") or {}).get("Labels") or {}


def version_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def newest(tags, pattern):
    found = [m.group(1) for m in (re.match(pattern, t) for t in tags) if m]
    return max(found, key=version_key) if found else None


def published(registry):
    """What the default branch published: {"state": ..., "images": [...]}. state is what a
    release records and compares: the upstream versions and the patches applied."""
    tags = registry.tags()
    sync = newest(tags, r"^syncstorage-rs-mysql-(\d+\.\d+\.\d+)$")
    fxa = newest(tags, r"^fxa-mono-(v\d+\.\d+\.\d+)$")
    pairing = newest(tags, r"^fxa-channelserver-(\d+\.\d+\.\d+)$")

    # an error here fails the run: a release is never decided on a guess
    def label(tag):
        return registry.labels(tag).get(PATCHES_LABEL) or "none"

    state = {
        "syncstorage-rs": sync,
        "fxa": fxa,
        "channelserver": pairing,
        "patches": {
            "syncstorage-rs": label(f"syncstorage-rs-mysql-{sync}") if sync else None,
            "fxa": label(f"fxa-mono-{fxa}") if fxa else None,
        },
    }
    images = []
    candidates = [(f"{n}-{sync}", n, sync) for n in SYNC_IMAGES if sync]
    candidates += [(f"fxa-mono-{fxa}", None, None)] if fxa else []
    candidates += [(f"fxa-channelserver-{pairing}", None, None)] if pairing else []
    candidates += [("admin-latest", None, None)]
    for tag, name, version in candidates:
        if tag not in tags:
            continue
        dated = None
        if name:
            dated = newest(tags, r"^(" + re.escape(f"{name}-{version}-") + r"\d{8}T\d{6})$")
        try:
            digest = registry.digest(tag)
        except urllib.error.URLError as e:
            print(f"release: the digest of {tag}: {e}", file=sys.stderr)
            digest = None
        images.append({"tag": tag, "dated": dated, "digest": digest})
    return {"state": state, "images": images}


def chart_versions(registry):
    try:
        return [t.replace("_", "+") for t in registry.tags(f"{registry.repository}/{CHART}")]
    except urllib.error.URLError as e:
        print(f"release: the chart's versions: {e}", file=sys.stderr)
        return []


def upstream_releases(repo, pattern, after, upto, ls_remote=None):
    """The release tags of an upstream repository in (after, upto], oldest first."""
    if not upto:
        return []
    try:
        out = (ls_remote or _ls_remote)(f"https://github.com/{repo}")
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"release: the tags of {repo}: {e}", file=sys.stderr)
        return [upto]
    tags = {l.rsplit("/", 1)[-1] for l in out.splitlines() if "refs/tags/" in l and not l.endswith("^{}")}
    tags = [t for t in tags if re.match(pattern, t)
            and (after is None or version_key(t) > version_key(after)) and version_key(t) <= version_key(upto)]
    return sorted(tags, key=version_key) or [upto]


def _ls_remote(url):
    return subprocess.run(["git", "ls-remote", "--tags", url], check=True, capture_output=True,
                          text=True, timeout=120).stdout


# ---- the decision ---------------------------------------------------------------------------

def previous_release(releases):
    """The newest published release of ours (tag vYYYY.MM.DD[.N]) and its recorded state."""
    ours = [r for r in releases if TAG.match(r.get("tag_name") or "") and not r.get("draft")]
    if not ours:
        return None, None
    latest = max(ours, key=lambda r: tag_key(r["tag_name"]))
    m = STATE.search(latest.get("body") or "")
    try:
        state = json.loads(m.group(1)) if m else None
    except ValueError:
        state = None
    return latest["tag_name"], state


def tag_key(tag):
    m = TAG.match(tag)
    return tuple(int(x or 1) for x in m.groups())


def changes(previous, current):
    """What changed between two states, as sentences; [] when nothing did."""
    out = []
    names = (("syncstorage-rs", "syncstorage-rs"), ("fxa", "accounts (mozilla/fxa)"),
             ("channelserver", "the pairing server"))
    for key, name in names:
        if (previous or {}).get(key) != current.get(key):
            out.append(f"{name} {(previous or {}).get(key) or 'none'} -> {current.get(key) or 'none'}")
    before, after = (previous or {}).get("patches") or {}, current.get("patches") or {}
    for key in sorted(set(before) | set(after)):
        if before.get(key) != after.get(key):
            out.append(f"the upstream patches of {key}: {before.get(key) or 'none'} -> {after.get(key) or 'none'}")
    return out


def decide(event, previous_tag, previous_state, current_state, unreleased):
    """(release?, why). event: tag, schedule or manual; unreleased: parse_section of Unreleased."""
    if event == "tag":
        return True, "a tag was pushed"
    if previous_tag is None:
        return True, "no previous release"
    if previous_state is None:
        return True, f"the previous release {previous_tag} has no recorded versions"
    why = changes(previous_state, current_state)
    if has_entries(unreleased):
        n = sum(len(e) for _, e in unreleased)
        why.append(f"CHANGELOG.md's Unreleased has {n} entr{'y' if n == 1 else 'ies'}")
    if why:
        return True, "; ".join(why)
    return False, (f"nothing new since {previous_tag}: syncstorage-rs {current_state.get('syncstorage-rs')}, "
                   f"accounts {current_state.get('fxa')}, pairing server {current_state.get('channelserver')} "
                   "and the upstream patches are those it published, and CHANGELOG.md's Unreleased is empty")


def next_tag(day, existing):
    """vYYYY.MM.DD, or with .N (2, 3, ...) when that day has a release already."""
    base = day.strftime("v%Y.%m.%d")
    taken = set(existing)
    if base not in taken:
        return base
    n = 2
    while f"{base}.{n}" in taken:
        n += 1
    return f"{base}.{n}"


def title(tag, state):
    return f"{tag} — syncstorage-rs {state.get('syncstorage-rs') or 'none'}, accounts {state.get('fxa') or 'none'}"


def tag_date(tag):
    m = TAG.match(tag)
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"


# ---- the notes ------------------------------------------------------------------------------

def upstream_lines(previous, current, ls_remote=None):
    previous = previous or {}
    lines = []

    def line(name, repo, key, pattern, notes):
        new, old = current.get(key), previous.get(key)
        if not new:
            return
        url = f"https://github.com/{repo}"
        if old == new:
            lines.append(f"- {name} **{new}**, unchanged: [release]({url}/releases/tag/{new})")
            return
        # with a previous release, every upstream release since; the first, its own only
        versions = upstream_releases(repo, pattern, old, new, ls_remote) if old else [new]
        shown = versions[-10:]
        links = ", ".join(f"[{v}]({url}/releases/tag/{v})" for v in shown)
        more = f" ({len(versions) - len(shown)} older)" if len(versions) > len(shown) else ""
        text = f"- {name} **{new}**" + (f" (was {old})" if old else "") + f": releases {links}{more}"
        if old:
            text += f"; [changes {old}...{new}]({url}/compare/{old}...{new})"
        lines.append(text + notes(new, old))

    # its CHANGELOG.md, and the diff of that file between the versions (GitHub's anchor of a
    # file in a comparison: diff-<sha256 of its path>)
    sync = f"https://github.com/{SYNC_UPSTREAM}"
    anchor = "diff-" + hashlib.sha256(b"CHANGELOG.md").hexdigest()
    line("syncstorage-rs", SYNC_UPSTREAM, "syncstorage-rs", r"^\d+\.\d+\.\d+$",
         lambda new, old: f"; [CHANGELOG.md]({sync}/blob/{new}/CHANGELOG.md)"
         + (f" ([its changes since {old}]({sync}/compare/{old}...{new}#{anchor}))" if old else ""))
    line("accounts (mozilla/fxa)", FXA_UPSTREAM, "fxa", r"^v\d+\.\d+\.\d+$", lambda new, old: "")
    line("pairing server (mozilla-services/channelserver)", PAIRING_UPSTREAM, "channelserver",
         r"^\d+\.\d+\.\d+$", lambda new, old: "")
    patches = current.get("patches") or {}
    before = previous.get("patches") or {}
    for key, name in (("syncstorage-rs", "syncstorage-rs"), ("fxa", "accounts")):
        if key in patches and patches[key] is not None:
            changed = "" if before.get(key) == patches[key] or not previous else f" (was `{before.get(key) or 'none'}`)"
            lines.append(f"- upstream patches applied to {name}: `{patches[key]}`{changed}")
    return lines


def notes(tag, unreleased, previous_tag, previous_state, current, chart, registry_host, repository,
          server="https://github.com", ls_remote=None):
    """The release notes, markdown, with the state recorded at the end (an HTML comment)."""
    state = current["state"]
    out = []
    body = render_sections(unreleased)
    if body:
        out += ["## Changes", "", body.rstrip("\n"), ""]
    out += ["## Upstream", ""]
    if previous_tag:
        out += [f"Since [{previous_tag}]({server}/{repository}/releases/tag/{previous_tag}):", ""]
    out += upstream_lines(previous_state, state, ls_remote) + [""]
    out += ["## Images", "", f"`{registry_host}/{repository.lower()}`, multi-arch (amd64, arm64):", "",
            "| Tag | Build | Digest |", "|---|---|---|"]
    for image in current["images"]:
        out.append(f"| `{image['tag']}` | {('`' + image['dated'] + '`') if image.get('dated') else ''} "
                   f"| {('`' + image['digest'] + '`') if image.get('digest') else ''} |")
    out.append("")
    version, versions = chart
    if version and version in versions:
        out += ["## Helm chart", "",
                f"`oci://{registry_host}/{repository.lower()}/{CHART}` version `{version}`.", ""]
    elif versions:
        best = max(versions, key=version_key)
        out += ["## Helm chart", "",
                f"The chart of this commit ({version or 'unknown'}) is not published; the newest published is "
                f"`{best}` (`oci://{registry_host}/{repository.lower()}/{CHART}`).", ""]
    out.append(f"<!-- release-state: {json.dumps(state, sort_keys=True)} -->")
    return "\n".join(out) + "\n"


# ---- plan -----------------------------------------------------------------------------------

def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def file_at(sha, path):
    try:
        return git("show", f"{sha}:{path}")
    except subprocess.CalledProcessError:
        return None


def default_branch():
    return os.environ.get("DEFAULT_BRANCH") or "main"


def wait_for_ci(gh, sha, own_run, timeout, interval=120):
    """Waits until every workflow run of the commit but this one completed: ok if each passed
    and one was a push to the default branch, or a manual run on it (its CI: the dependencies
    workflow starts main's CI so after it merged, docs/development/dependencies.md), else the reason."""
    deadline = time.time() + timeout
    while True:
        runs = [r for r in gh.runs_of(sha) if str(r.get("id")) != str(own_run)
                and r.get("path", "").split("@")[0] != ".github/workflows/release.yml"]
        latest = {}
        for r in sorted(runs, key=lambda r: r.get("created_at") or ""):
            latest[(r.get("path") or r.get("name"), r.get("event"), r.get("head_branch"))] = r
        pending = [r for r in latest.values() if r.get("status") != "completed"]
        if not pending:
            break
        if time.time() > deadline:
            return f"CI of {sha[:12]} still running after {timeout // 60} min: " + ", ".join(r["name"] for r in pending)
        print(f"release: waiting for {', '.join(r['name'] for r in pending)} on {sha[:12]}", file=sys.stderr)
        time.sleep(interval)
    failed = [r for r in latest.values() if r.get("conclusion") not in ("success", "skipped", "neutral")]
    if failed:
        return f"CI of {sha[:12]} did not pass: " + ", ".join(f"{r['name']} ({r['conclusion']})" for r in failed)
    if not any(r.get("event") in ("push", "workflow_dispatch") and r.get("head_branch") == default_branch()
               for r in latest.values()):
        return (f"no CI run of {sha[:12]} on {default_branch()}: tag a commit that was the head of a push"
                f" to {default_branch()}")
    return None


def weekly_target(gh, now):
    """The commit the weekly runs built, or (None, why) while one of them is not done."""
    sha = None
    for workflow in WEEKLY:
        run = gh.latest_run(workflow, "schedule")
        if run is None:
            return None, f"no scheduled run of {workflow} yet"
        created = datetime.datetime.strptime(run["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        # the same week's: a scheduled run can start hours late, and take hours
        if now - created > datetime.timedelta(hours=36):
            return None, f"waiting for this week's scheduled run of {workflow} (the latest started {run['created_at']})"
        if run.get("status") != "completed":
            return None, f"waiting for the scheduled run of {workflow} ({run.get('html_url')}), {run.get('status')}"
        if workflow == WEEKLY[0]:
            sha = run["head_sha"]
    return sha, None


def set_outputs(**values):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            for k, v in values.items():
                f.write(f"{k}={v}\n")


def plan(args):
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        sys.exit("release: GITHUB_REPOSITORY (owner/name) is not set")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    server = os.environ.get("GITHUB_SERVER_URL") or "https://github.com"
    host = os.environ.get("REGISTRY") or "ghcr.io"
    gh = GitHub(repository, token, os.environ.get("GITHUB_API_URL"), server)
    registry = Registry(host, repository, token)
    now = datetime.datetime.now(datetime.timezone.utc)

    def stop(release, why, **extra):
        print(f"release: {'release' if release else 'no release'}: {why}")
        set_outputs(release="true" if release and not args.dry_run else "false", **extra)
        return 0

    target, tag = args.target, args.tag
    if args.event == "tag":
        if not tag or not TAG.match(tag):
            sys.exit(f"release: {tag!r} is not a release tag vYYYY.MM.DD[.N]")
        try:
            target = target or git("rev-parse", f"{tag}^{{commit}}").strip()
        except subprocess.CalledProcessError:
            sys.exit(f"release: no tag {tag} in this clone")
        try:
            git("merge-base", "--is-ancestor", target, f"origin/{default_branch()}")
        except subprocess.CalledProcessError:
            sys.exit(f"release: {tag} ({target[:12]}) is not a commit of {default_branch()}")
        if not args.dry_run:
            problem = wait_for_ci(gh, target, os.environ.get("GITHUB_RUN_ID"), args.wait)
            if problem:
                sys.exit(f"release: {problem}")
    elif args.event == "schedule" and not target:
        target, why = weekly_target(gh, now)
        if not target:
            return stop(False, why)
    target = git("rev-parse", f"{target or 'HEAD'}^{{commit}}").strip()

    current = published(registry)
    previous_tag, previous_state = previous_release(gh.releases())
    unreleased = unreleased_entries(file_at(target, "CHANGELOG.md"))
    release, why = decide(args.event, previous_tag, previous_state, current["state"], unreleased)
    if args.event != "tag":
        tag = next_tag(now.date(), gh.tags(now.strftime("v%Y.%m.%d")))
    chart_yaml = file_at(target, f"{CHART}/Chart.yaml") or ""
    m = re.search(r"^version:\s*['\"]?([^'\"\s]+)", chart_yaml, re.M)
    chart = (m.group(1) if m else None, chart_versions(registry))
    text = notes(tag, unreleased, previous_tag, previous_state, current, chart, host, repository, server)
    heading = title(tag, current["state"])
    upstream = f"Upstream only: syncstorage-rs {current['state'].get('syncstorage-rs')}, accounts {current['state'].get('fxa')}."
    if args.output:
        os.makedirs(args.output, exist_ok=True)
        with open(os.path.join(args.output, "notes.md"), "w", encoding="utf-8") as f:
            f.write(text)
        with open(os.path.join(args.output, "unreleased.md"), "w", encoding="utf-8") as f:
            f.write(render_sections(unreleased))
        with open(os.path.join(args.output, "decision.json"), "w", encoding="utf-8") as f:
            json.dump({"release": release, "why": why, "tag": tag, "target": target, "title": heading,
                       "date": tag_date(tag), "upstream": upstream, "previous": previous_tag,
                       "state": current["state"]}, f, indent=2)
    print(f"release: target {target}, previous release {previous_tag or 'none'}")
    print(f"release: {'would publish' if args.dry_run else 'publishing'} {heading}" if release else
          f"release: {heading} is not published")
    print("----- notes.md -----\n" + text + "--------------------")
    return stop(release, why, tag=tag, target=target, title=heading)


def changelog(args):
    with open(args.file, encoding="utf-8") as f:
        text = f.read()
    released = None
    if args.released:
        with open(args.released, encoding="utf-8") as f:
            released = parse_section(f.read().splitlines(keepends=True))
    new = release_changelog(text, args.version, args.date, released, args.upstream or "")
    if new != text:
        with open(args.file, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"changelog: {args.file}: Unreleased moved into {args.version}")
    else:
        print(f"changelog: {args.file}: nothing to change")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    pp = sub.add_parser("plan")
    pp.add_argument("--event", choices=("tag", "schedule", "manual"), required=True)
    pp.add_argument("--tag")
    pp.add_argument("--target", help="the commit (default: the weekly runs', or HEAD)")
    pp.add_argument("--output")
    pp.add_argument("--dry-run", action="store_true")
    pp.add_argument("--wait", type=int, default=5 * 3600, help="seconds to wait for the CI of a tag")
    pc = sub.add_parser("changelog")
    pc.add_argument("--version", required=True)
    pc.add_argument("--date", required=True)
    pc.add_argument("--released")
    pc.add_argument("--upstream")
    pc.add_argument("file")
    args = p.parse_args(argv)
    return plan(args) if args.command == "plan" else changelog(args)


if __name__ == "__main__":
    sys.exit(main())
