#!/usr/bin/env python3
"""The upstream pull requests of upstream-patches.yml, for one image build.

Usage:
  upstream-patches.py plan  <component> <release-tag>
  upstream-patches.py apply <component> <release-tag> <source-checkout-dir>

component: fxa-mono or syncstorage-rs; release-tag: the upstream tag being built.

For each entry of the component, the pull request as GitHub has it now (gh api), checked
against the entry first: its head repository must be head_repo, the pinned sha must be in
its history (compare sha...head: identical or ahead) and base an ancestor of sha; else
error, exit 1. Then:
  - merged and in the release (compare merge_commit_sha...tag: identical or ahead):
    obsolete, not applied; with apply its changes must be in the sources (they apply in
    reverse), else error
  - closed without being merged: error, exit 1
  - open, or merged after the release: applied as of the pinned sha (apply), the diff
    base...sha (both pinned: the reviewed changes whatever happens to the pull request);
    a ::notice:: when its head is past sha. With apply, a patch already in the sources
    (it applies in reverse) is obsolete too; one that does not apply is an error, exit 1
plan decides only (for the reuse of images and the rebuilds), apply also patches the
checkout (git apply; a depth-1 checkout has no blobs for a 3-way merge).

Ports: an entry with `ports: <dir>` (a directory of this repository) may hold
<dir>/<release-tag>.diff, the same change made by hand for a release the pull request does not
apply to (e.g. code moved between the release and the pull request's base). Building that
release, the file is applied instead of base...sha (the checks of the pull request and the
merged/closed decisions are the same); the reference gets +<release-tag>
(owner/repo#pr@base7..sha7+<release-tag>). Without a file for the release, base...sha as
always; with apply, when it neither applies nor is in the sources (and no release pin of an
older release does, see below), the newest port of an older release (by version) is tried with git apply --check: applied when it applies, the
reference names the port used (+<its release-tag>) and a ::warning:: asks for a port of this
release to be reviewed. When neither applies the build fails, so a new release does not go
out without the patch. plan does not try it (no sources): its reference stays base...sha.

Release pins: an entry with `releases:` pins, per release tag, another commit of the pull
request and its base (`<tag>:` then `base:` and `sha:`), for a release the entry's base...sha
does not apply to (the pull request was rebased on a newer upstream main, say). The pinned sha
must have been a head of the pull request: in its history, or a head before a force push (the
pull request's HeadRefForcePushedEvent, before and after), and base an ancestor of it; the
entry's own base and sha are checked as always. Building that release, base...sha of the pin
is applied instead of the entry's, and the reference is that of the commit applied
(owner/repo#pr@base7..sha7 of the pin, no +tag: it is a commit of the pull request). The order
for a release: its port, else its release pin, else the entry's base...sha; with apply, when
that neither applies nor is in the sources, the pin of the newest older release (git apply
--check, a ::warning::), then the newest older port, else the build fails. A pin GitHub can no
longer serve fails: make it a port.

Outputs (GITHUB_OUTPUT, and printed): applied (space-separated owner/repo#pr@base7..sha7),
label (applied, or "none"), key (12 hex of label's sha256, for cache keys), obsolete
(the same form), obsolete_json ([{"id", "pr", "when_released"}]). A summary for
GITHUB_STEP_SUMMARY. Environment: UPSTREAM_PATCHES_FILE (default: upstream-patches.yml at
the root of this repository), GH_TOKEN for gh.

Python 3 standard library and gh only. Tests: tests/test_upstream_patches.py.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

COMPONENTS = ("fxa-mono", "syncstorage-rs")
FIELDS = ("id", "repo", "pr", "head_repo", "base", "sha", "component", "why", "when_released")
OPTIONAL = ("ports", "releases")
PIN_FIELDS = ("base", "sha")
LABEL = "org.firefox-sync.upstream-patches"


class Fail(Exception):
    """An entry that needs a decision: the build must fail."""


# --- upstream-patches.yml: a list of mappings of plain or folded (>-) scalars; releases: a
# mapping of release tags to base and sha (plain scalars, indented by 4 and 6) ---

def _scalar(text, where):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    if text[:1] in ("[", "{", "&", "*", "!", "|"):
        raise ValueError(f"{where}: only plain or quoted scalars and >- blocks: {text}")
    return re.sub(r"\s+#.*$", "", text)


def _releases(lines, i, where):
    """The mapping under releases: from line i: {tag: {"base", "sha"}}, and the next line."""
    pins, pin = {}, None
    while i < len(lines):
        line = lines[i]
        here = f"line {i + 1}"
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        if not line.startswith("    "):
            break
        i += 1
        m = re.match(r"^    ([A-Za-z0-9_.+-]+):\s*(?:#.*)?$", line)
        if m:
            if m.group(1) in pins:
                raise ValueError(f"{here}: release {m.group(1)} twice")
            pin = pins[m.group(1)] = {}
            continue
        m = re.match(r"^      ([a-z_]+):(?: (.*))?$", line)
        if not m or pin is None:
            raise ValueError(f"{here}: expected '    <release-tag>:' or '      base|sha: <sha>': {line}")
        if m.group(1) not in PIN_FIELDS:
            raise ValueError(f"{here}: a release pin has base and sha only: {m.group(1)}")
        if m.group(1) in pin:
            raise ValueError(f"{here}: {m.group(1)} twice")
        pin[m.group(1)] = _scalar(m.group(2) or "", here)
    if not pins:
        raise ValueError(f"{where}: releases without any release")
    return pins, i


def parse(text):
    entries = []
    lines = text.splitlines()
    i = 0
    current = None
    while i < len(lines):
        line = lines[i]
        where = f"line {i + 1}"
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("- "):
            current = {}
            entries.append(current)
            line = "  " + line[2:]
        elif current is None or not line.startswith("  ") or line.startswith("   "):
            raise ValueError(f"{where}: expected '- key: value' or '  key: value': {line}")
        m = re.match(r"^  ([a-z_]+):(?: (.*))?$", line)
        if not m:
            raise ValueError(f"{where}: expected 'key: value': {line}")
        key, value = m.group(1), (m.group(2) or "").strip()
        if key in current:
            raise ValueError(f"{where}: {key} twice")
        if key == "releases":
            if value:
                raise ValueError(f"{where}: releases: a mapping on the next lines ('    <release-tag>:')")
            value, i = _releases(lines, i, where)
        elif value in (">", ">-"):
            block = []
            while i < len(lines) and (lines[i].startswith("    ") or not lines[i].strip()):
                block.append(lines[i].strip())
                i += 1
            value = " ".join(b for b in block if b)
        else:
            value = _scalar(value, where)
        current[key] = value
    for n, e in enumerate(entries, 1):
        missing = [f for f in FIELDS if not e.get(f)]
        if missing:
            raise ValueError(f"entry {n} ({e.get('id', '?')}): missing {', '.join(missing)}")
        unknown = sorted(set(e) - set(FIELDS) - set(OPTIONAL))
        if unknown:
            raise ValueError(f"entry {n} ({e['id']}): unknown {', '.join(unknown)}")
        if e["component"] not in COMPONENTS:
            raise ValueError(f"entry {n} ({e['id']}): component {e['component']}, not one of {', '.join(COMPONENTS)}")
        for field in ("sha", "base"):
            if not re.fullmatch(r"[0-9a-f]{40}", e[field]):
                raise ValueError(f"entry {n} ({e['id']}): {field} must be a full commit sha")
        for field in ("repo", "head_repo"):
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", e[field]):
                raise ValueError(f"entry {n} ({e['id']}): {field} must be owner/name")
        if "ports" in e and not re.fullmatch(r"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*", e["ports"]) \
                or ".." in e.get("ports", "").split("/"):
            raise ValueError(f"entry {n} ({e['id']}): ports must be a relative directory of this repository")
        for tag, pin in e.get("releases", {}).items():
            for field in PIN_FIELDS:
                if not re.fullmatch(r"[0-9a-f]{40}", pin.get(field, "")):
                    raise ValueError(f"entry {n} ({e['id']}): releases {tag}: {field} must be a full commit sha")
        if not e["pr"].isdigit():
            raise ValueError(f"entry {n} ({e['id']}): pr must be a number")
        e["pr"] = int(e["pr"])
    ids = [e["id"] for e in entries]
    if len(ids) != len(set(ids)):
        raise ValueError("ids must be unique")
    return entries


def pinned(entry):
    """base and sha of what is applied: the release pin's when there is one, else the entry's."""
    pin = entry.get("pin")
    return (pin["base"], pin["sha"]) if pin else (entry["base"], entry["sha"])


def ref(entry):
    # base too: a correction of base alone changes what is applied, the label and the keys;
    # a port the release it is for (its file is what is applied); a release pin is a commit of
    # the pull request: its own base..sha
    port = f"+{entry['port_tag']}" if entry.get("port") else ""
    base, sha = pinned(entry)
    return f"{entry['repo']}#{entry['pr']}@{base[:7]}..{sha[:7]}{port}"


def own(entry):
    """The entry as upstream-patches.yml has it: without the port or release pin chosen."""
    return {k: v for k, v in entry.items() if k not in ("port", "port_tag", "fallback", "pin")}


def with_pin(entry, tag):
    """The entry, with pin ({"tag", "base", "sha"}) when it has a release pin for tag and no port
    for it (a port, a change by hand, comes first)."""
    if entry.get("port") or tag not in entry.get("releases", {}):
        return entry
    return dict(entry, pin=dict(entry["releases"][tag], tag=tag))


def fallback_pin(entry, tag):
    """For an entry without a port or pin for tag: the pin of the newest older release, as
    with_pin would have it for that release (and fallback: the release built), or None."""
    if entry.get("port") or entry.get("pin") or _version(tag) is None:
        return None
    older = [(_version(t), t) for t in entry.get("releases", {})]
    older = [(v, t) for v, t in older if v is not None and v < _version(tag)]
    if not older:
        return None
    return dict(with_pin(entry, max(older)[1]), fallback=tag)


def with_port(entry, tag, root):
    """The entry, with port (the file) and port_tag when its ports directory has one for tag."""
    if not entry.get("ports") or not re.fullmatch(r"[A-Za-z0-9_.+-]+", tag):
        return entry
    path = os.path.join(root, entry["ports"], f"{tag}.diff")
    if not os.path.isfile(path):
        return entry
    return dict(entry, port=path, port_tag=tag)


def _version(tag):
    """v1.347.3 -> (1, 347, 3); None for a tag that is not a version."""
    m = re.fullmatch(r"v?([0-9]+(?:\.[0-9]+)*)", tag)
    return tuple(int(n) for n in m.group(1).split(".")) if m else None


def fallback_port(entry, tag, root):
    """For an entry without a port for tag: the newest port of an older release, as with_port
    would have it for that release (port, port_tag, and fallback: the release built), or None.
    None for an entry with a release pin for tag: that pin is what the release gets."""
    if entry.get("port") or entry.get("pin") or not entry.get("ports") or _version(tag) is None:
        return None
    directory = os.path.join(root, entry["ports"])
    if not os.path.isdir(directory):
        return None
    older = [(_version(n[:-5]), n[:-5]) for n in os.listdir(directory)
             if n.endswith(".diff") and os.path.isfile(os.path.join(directory, n))]
    older = [(v, t) for v, t in older if v is not None and v < _version(tag)]
    if not older:
        return None
    port_tag = max(older)[1]
    return dict(entry, port=os.path.join(directory, f"{port_tag}.diff"), port_tag=port_tag, fallback=tag)


# --- GitHub, through gh (replaced by a fake in the tests) ---

class GitHub:
    def _api(self, path, accept=None):
        cmd = ["gh", "api"]
        if accept:
            cmd += ["-H", f"Accept: {accept}"]
        result = subprocess.run(cmd + [path], capture_output=True, text=True)
        if result.returncode != 0:
            raise Fail(f"gh api {path}: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    def pull(self, repo, number):
        return json.loads(self._api(f"repos/{repo}/pulls/{number}"))

    def contains(self, repo, commit, ref):
        """Whether ref has commit in its history: compare commit...ref is identical or ahead."""
        status = json.loads(self._api(f"repos/{repo}/compare/{commit}...{ref}"))["status"]
        return status in ("identical", "ahead")

    def former_heads(self, repo, number):
        """The heads the pull request had before and after each force push (HeadRefForcePushedEvent
        of GraphQL; the REST timeline has only the head after one, not the first head)."""
        owner, name = repo.split("/", 1)
        query = ("query($owner: String!, $name: String!, $number: Int!, $after: String) {"
                 " repository(owner: $owner, name: $name) { pullRequest(number: $number) {"
                 " timelineItems(first: 100, after: $after, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT]) {"
                 " pageInfo { hasNextPage endCursor }"
                 " nodes { ... on HeadRefForcePushedEvent { beforeCommit { oid } afterCommit { oid } } } } } } }")
        heads, after = set(), None
        while True:
            args = ["-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={number}"]
            if after:
                args += ["-f", f"after={after}"]
            items = json.loads(self._graphql(args))["data"]["repository"]["pullRequest"]["timelineItems"]
            for node in items["nodes"]:
                for commit in (node.get("beforeCommit"), node.get("afterCommit")):
                    if commit and commit.get("oid"):
                        heads.add(commit["oid"])
            if not items["pageInfo"]["hasNextPage"]:
                return heads
            after = items["pageInfo"]["endCursor"]

    def _graphql(self, args):
        result = subprocess.run(["gh", "api", "graphql", *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise Fail(f"gh api graphql: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    def diff(self, repo, base, sha):
        """The changes of sha since its merge base with base (compare base...sha)."""
        return self._api(f"repos/{repo}/compare/{base}...{sha}", accept="application/vnd.github.diff")


# --- the decisions ---

def check_pin(entry, pull, gh):
    """The pull request is the one reviewed: its head repository, sha in its history, base
    an ancestor of sha (the entry's own pin; a release pin is checked by check_release_pin).
    Returns the notices."""
    name = f"{ref(own(entry))} ({entry['id']})"
    head_repo = (pull["head"].get("repo") or {}).get("full_name")
    if head_repo is None and not pull.get("merged"):
        raise Fail(f"{name}: the pull request's head repository is gone: decide (remove the entry or pin another pull request)")
    if head_repo is not None and head_repo != entry["head_repo"]:
        raise Fail(f"{name}: the pull request's head is {head_repo}, upstream-patches.yml says {entry['head_repo']}")
    head = pull["head"]["sha"]
    notices = []
    if head != entry["sha"]:
        if not gh.contains(entry["repo"], entry["sha"], head):
            raise Fail(f"{name}: sha {entry['sha'][:7]} is not in the history of the pull request (head {head[:7]}): "
                       f"pin a commit of the pull request")
        notices.append(f"{name}: the pull request is at {head[:7]} now, still applying the reviewed "
                       f"{entry['sha'][:7]}: review the new commits and move sha in upstream-patches.yml")
    if not gh.contains(entry["repo"], entry["base"], entry["sha"]):
        raise Fail(f"{name}: base {entry['base'][:7]} is not an ancestor of sha {entry['sha'][:7]}")
    return notices


def check_release_pin(entry, pull, gh):
    """The release pin of the entry was a head of the pull request (in its history, or a head
    before a force push) and its base an ancestor of it; Fail when not, or when GitHub can no
    longer serve the commit."""
    pin = entry["pin"]
    name = f"{ref(entry)} ({entry['id']}, releases {pin['tag']})"
    port = (f"{entry['ports']}/{pin['tag']}.diff" if entry.get("ports") else
            f"upstream-patches/{entry['id']}/{pin['tag']}.diff with ports: upstream-patches/{entry['id']}")
    head = pull["head"]["sha"]
    if pin["sha"] != head and pin["sha"] not in gh.former_heads(entry["repo"], entry["pr"]):
        try:
            contained = gh.contains(entry["repo"], pin["sha"], head)
        except Fail as e:
            raise Fail(f"{name}: sha {pin['sha'][:7]} is not a former head of the pull request and GitHub "
                       f"does not compare it to the head ({e}): pin a head the pull request had")
        if not contained:
            raise Fail(f"{name}: sha {pin['sha'][:7]} was never a head of the pull request (not in its history "
                       f"nor a head before a force push): pin a head the pull request had")
    try:
        ancestor = gh.contains(entry["repo"], pin["base"], pin["sha"])
    except Fail as e:
        raise Fail(f"{name}: GitHub can no longer serve {pin['base'][:7]}...{pin['sha'][:7]} ({e}): "
                   f"save the change as a port instead ({port}) and remove the release pin")
    if not ancestor:
        raise Fail(f"{name}: base {pin['base'][:7]} is not an ancestor of sha {pin['sha'][:7]}")


def decide(entry, pull, gh, tag):
    """apply or obsolete for one entry, and its notices; Fail for a decision to take."""
    notices = check_pin(entry, pull, gh)
    if entry.get("pin"):
        check_release_pin(entry, pull, gh)
    if pull.get("merged"):
        merge = pull.get("merge_commit_sha")
        if merge and gh.contains(entry["repo"], merge, tag):
            return "obsolete", f"merged ({merge[:7]}) and in {tag}", notices
        return "apply", f"merged ({(merge or '?')[:7]}), not in {tag} yet", notices
    if pull["state"] == "closed":
        raise Fail(f"{ref(entry)} ({entry['id']}) was closed without being merged: "
                   f"remove the entry (and its workaround, see when_released) or replace it")
    return "apply", "open", notices


def git(checkout, *args, stdin=None):
    return subprocess.run(["git", "-C", checkout, *args], input=stdin, capture_output=True, text=True)


def _pin_diff(entry, gh):
    """base...sha of what is applied (the release pin's or the entry's)."""
    base, sha = pinned(entry)
    try:
        return gh.diff(entry["repo"], base, sha)
    except Fail as e:
        if not entry.get("pin"):
            raise
        raise Fail(f"{ref(entry)} ({entry['id']}, releases {entry['pin']['tag']}): GitHub can no longer serve "
                   f"{base[:7]}...{sha[:7]} ({e}): save the change as a port instead and remove the release pin")


def apply_patch(entry, pull, gh, checkout, released=False, tag=None, root=None):
    """Applies the pinned changes; returns "applied" or "present" (already in the sources), and
    the entry as applied: with the fallback (see fallback_pin, fallback_port) when that is what
    applied. released: the release has the pull request, its changes must be there. tag and
    root: the release built and the directory of the ports, for the fallbacks."""
    name = f"{ref(entry)} ({entry['id']})"
    if entry.get("port"):
        with open(entry["port"]) as f:
            diff = f.read()
        if not diff.strip():
            raise Fail(f"{name}: the port {entry['ports']}/{entry['port_tag']}.diff is empty")
    else:
        diff = _pin_diff(entry, gh)
        if not diff.strip():
            base, sha = pinned(entry)
            raise Fail(f"{name}: no changes between {base[:7]} and {sha[:7]}")
    files = len(re.findall(r"^diff --git ", diff, re.M))
    # a port is made by hand for the release: its files are not the pull request's
    if not entry.get("port") and pinned(entry)[1] == pull["head"]["sha"] and pull.get("changed_files") not in (None, files):
        raise Fail(f"{name}: {files} files changed since base {pinned(entry)[0][:7]}, the pull request "
                   f"changes {pull['changed_files']}: retargeted or rebased? Review it and pin base and sha again")
    with tempfile.NamedTemporaryFile("w", suffix=".diff", delete=False) as f:
        f.write(diff)
        path = f.name
    try:
        present = git(checkout, "apply", "--reverse", "--check", path).returncode == 0
        if released:
            if present:
                return "present", entry
            raise Fail(f"{name} is merged and in the release, but its changes are not in the sources "
                       f"(changed again since?): remove the entry and do what its when_released says")
        result = git(checkout, "apply", "--check", path)
        if result.returncode == 0:
            result = git(checkout, "apply", path)
            if result.returncode == 0:
                return "applied", entry
        elif present:
            return "present", entry
        tried = []
        for fallback in ((fallback_pin(entry, tag), fallback_port(entry, tag, root)) if tag and root else ()):
            if not fallback:
                continue
            if fallback.get("port"):
                tried.append(f"the newest port, {entry['ports']}/{fallback['port_tag']}.diff")
                with open(fallback["port"]) as f:
                    status = _apply_fallback(f.read(), checkout)
            else:
                check_release_pin(fallback, pull, gh)
                tried.append(f"the release pin of {fallback['pin']['tag']}, {ref(fallback)}")
                status = _apply_fallback(_pin_diff(fallback, gh), checkout)
            if status:
                return status, fallback
        if entry.get("port"):
            raise Fail(f"{name}: the port {entry['ports']}/{entry['port_tag']}.diff does not apply to the release: "
                       f"{(result.stderr or result.stdout).strip()}\nfix the port, or remove it and the entry")
        if entry.get("pin"):
            raise Fail(f"{name}: the release pin of {entry['pin']['tag']} does not apply to the release: "
                       f"{(result.stderr or result.stdout).strip()}\npin another head of the pull request for it, "
                       f"or a port, or remove the entry")
        hint = (f", or add a port for it ({entry['ports']}/<release-tag>.diff)" if entry.get("ports") else "")
        tried = "".join(f"\nnor does {t}" for t in tried)
        raise Fail(f"{name} does not apply to the release: {(result.stderr or result.stdout).strip()}{tried}\n"
                   f"rebase the pull request and pin its new head (and base), or pin for this release (releases:) "
                   f"a head of the pull request that applies{hint}, or remove the entry")
    finally:
        os.unlink(path)


def _apply_fallback(diff, checkout):
    """The change of an older release (its pin's diff or its port) on this one: "applied" or
    "present" when it applies (or is in the sources) cleanly, None otherwise (nothing changed)."""
    if not diff.strip():
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".diff", delete=False) as f:
        f.write(diff)
        path = f.name
    try:
        if git(checkout, "apply", "--check", path).returncode == 0:
            if git(checkout, "apply", path).returncode == 0:
                return "applied"
            return None
        if git(checkout, "apply", "--reverse", "--check", path).returncode == 0:
            return "present"
        return None
    finally:
        os.unlink(path)


def run(entries, component, tag, gh, checkout=None, log=print, root=None):
    """The decisions for the entries of component, applied to checkout when given. root: the
    directory the ports are in (that of upstream-patches.yml)."""
    result = {"applied": [], "obsolete": [], "notices": [], "warnings": [], "rows": []}
    root = root or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    chosen = [with_pin(with_port(e, tag, root), tag) for e in entries if e["component"] == component]
    decisions = []
    errors = []
    for entry in chosen:
        pull = gh.pull(entry["repo"], entry["pr"])
        try:
            action, state, notices = decide(entry, pull, gh, tag)
        except Fail as e:
            errors.append(str(e))
            continue
        result["notices"] += notices
        if entry.get("pin"):
            state = f"{state}, the release pin of {tag}"
        decisions.append((entry, pull, action, state))
    if errors:
        raise Fail("\n".join(errors))
    for entry, pull, action, state in decisions:
        if checkout:
            status, entry = apply_patch(entry, pull, gh, checkout, released=(action == "obsolete"),
                                        tag=tag, root=root)
            if entry.get("fallback") and not entry.get("port"):
                state = f"{state}, base...sha does not apply: the release pin of {entry['pin']['tag']}"
                if status == "applied":
                    result["warnings"].append(
                        f"{ref(entry)} ({entry['id']}): base...sha does not apply to {tag}, the release pin of "
                        f"{entry['pin']['tag']} ({ref(entry)}) applied cleanly and was used: review it on {tag} and "
                        f"pin it (or another head of the pull request) for {tag} under releases")
            elif entry.get("fallback"):
                state = f"{state}, base...sha does not apply: the port of {entry['port_tag']}"
                if status == "applied":
                    result["warnings"].append(
                        f"{ref(entry)} ({entry['id']}): base...sha does not apply to {tag}, the port of "
                        f"{entry['port_tag']} ({entry['ports']}/{entry['port_tag']}.diff) applied cleanly and was "
                        f"used: review it on {tag} and add {entry['ports']}/{tag}.diff")
            if status == "present" and action == "apply":
                action, state = "obsolete", f"{state}, its changes already in {tag}"
        if action == "apply":
            result["applied"].append(entry)
        else:
            result["obsolete"].append(entry)
        result["rows"].append((entry, state, action if checkout or action == "obsolete" else "to apply"))
        log(f"{ref(entry)} ({entry['id']}): {state}: {action if checkout or action == 'obsolete' else 'to apply'}")
    return result


def outputs(result):
    applied = " ".join(ref(e) for e in result["applied"])
    label = applied or "none"
    return {
        "applied": applied,
        "label": label,
        "key": hashlib.sha256(label.encode()).hexdigest()[:12],
        "obsolete": " ".join(ref(e) for e in result["obsolete"]),
        "obsolete_json": json.dumps([{"id": e["id"], "pr": ref(e), "when_released": e["when_released"]}
                                     for e in result["obsolete"]], separators=(",", ":")),
    }


def summary(result, component, tag):
    lines = [f"### Upstream patches, {component} {tag}", ""]
    if not result["rows"]:
        return "\n".join(lines + ["None in upstream-patches.yml.", ""])
    lines += ["| Pull request | | State | Image |", "| --- | --- | --- | --- |"]
    for entry, state, action in result["rows"]:
        url = f"https://github.com/{entry['repo']}/pull/{entry['pr']}"
        lines.append(f"| [{ref(entry)}]({url}) | {entry['id']} | {state} | {action} |")
    lines.append("")
    lines.append(f"Label {LABEL}: `{outputs(result)['label']}`")
    for n in result["warnings"] + result["notices"]:
        lines.append(f"- {n}")
    return "\n".join(lines + [""])


def main(argv):
    if len(argv) < 3 or argv[0] not in ("plan", "apply") or (argv[0] == "apply") != (len(argv) == 4) or len(argv) > 4:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    mode, component, tag = argv[:3]
    checkout = argv[3] if mode == "apply" else None
    if component not in COMPONENTS:
        print(f"component: one of {', '.join(COMPONENTS)}", file=sys.stderr)
        return 2
    path = os.environ.get("UPSTREAM_PATCHES_FILE") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "upstream-patches.yml")
    try:
        with open(path) as f:
            entries = parse(f.read())
        result = run(entries, component, tag, GitHub(), checkout, root=os.path.dirname(os.path.abspath(path)))
    except (Fail, ValueError) as e:
        for line in str(e).splitlines():
            print(f"::error title=upstream-patches.yml::{line}")
        return 1
    for n in result["warnings"]:
        print(f"::warning title=upstream-patches.yml::{n}")
    for n in result["notices"]:
        print(f"::notice title=upstream-patches.yml::{n}")
    out = outputs(result)
    for k, v in out.items():
        print(f"{k}={v}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.writelines(f"{k}={v}\n" for k, v in out.items())
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary(result, component, tag))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
