"""MkDocs hook: render docs/, written for GitHub, the same way on the site (mkdocs.yml).

The pages stay GitHub markdown. This hook bridges what Python-Markdown reads differently:

- Links that leave docs/ (/db/setup-manifest, /charts/firefox-sync, the root README.md) and
  links to files of docs/ that are not on the site (/docs/images/admin) become
  https://github.com/<repo>/blob/main/<path>, or tree/main/ for a directory, with the repo
  taken from repo_url. Links between pages stay relative.
- Lists: GitHub (CommonMark) nests by the item's content column (2 spaces after "-", 3 after
  "1."), Python-Markdown by 4 spaces. The indentation of list items is rewritten in multiples
  of 4, and a blank line is put before a list that follows a paragraph.
- <details><summary>Title</summary> ... </details> at the start of a line becomes a collapsed
  "??? note" block (pymdownx.details), so its markdown is rendered.
- Duplicate headings get GitHub's ids, -1, -2, instead of _1, _2.
- A backslash-escaped pipe in the code of a table cell renders as a plain pipe, as on GitHub.

The markdown files are never changed: only what MkDocs reads of them.
"""

import logging
import os
import posixpath
import re
from urllib.parse import unquote

import markdown.extensions.toc
from markdown.extensions import Extension
from markdown.treeprocessors import Treeprocessor

log = logging.getLogger("mkdocs.hooks.repo_links")
_state = {"repo": None, "root": None, "docs": None, "files": None, "page": None}


def _unique(id, ids):
    base, n = id, 0
    while id in ids or not id:
        n += 1
        id = f"{base}-{n}"
    ids.add(id)
    return id


markdown.extensions.toc.unique = _unique


def on_config(config):
    m = re.match(r"https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", config.repo_url or "")
    if not m:
        raise ValueError(f"repo_links: repo_url is not a GitHub repository: {config.repo_url!r}")
    _state["repo"] = f"https://github.com/{m.group(1)}"
    _state["root"] = os.path.dirname(os.path.abspath(config.config_file_path))
    _state["docs"] = os.path.relpath(os.path.abspath(config.docs_dir), _state["root"]).replace(os.sep, "/")
    config.markdown_extensions.append(_RepoLinks())
    return config


def on_files(files, config):
    _state["files"] = files
    return files


def on_page_markdown(markdown, page, config, files):
    _state["page"] = page
    return _details(_lists(markdown))


# --- links ------------------------------------------------------------------------------

def _site_file(src):
    f = _state["files"].get_file_from_path(src) if _state["files"] else None
    return f is not None and not f.inclusion.is_excluded()


def _rewrite(url):
    if not url or url.startswith("#") or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url) or url.startswith("//"):
        return url
    path, sep, frag = url.partition("#")
    if not path:
        return url
    page_dir = posixpath.dirname(_state["page"].file.src_uri)
    docs = _state["docs"]
    if path.startswith("/"):
        repo_path = posixpath.normpath(unquote(path).lstrip("/") or ".")
    else:
        repo_path = posixpath.normpath(posixpath.join(docs, page_dir, unquote(path)))
    if repo_path.startswith("../"):
        return url  # outside the repository: left to MkDocs' warning
    if repo_path == docs or repo_path.startswith(docs + "/"):
        src = repo_path[len(docs) + 1:]
        if src and _site_file(src):
            if path.startswith("/"):  # /docs/x.md: relative, as MkDocs wants  # check-links: ignore
                rel = posixpath.relpath(src, page_dir or ".")
                return rel + sep + frag
            return url
    full = os.path.join(_state["root"], repo_path)
    if not os.path.exists(full):
        log.warning(f"Doc file '{_state['page'].file.src_uri}' links to '{url}', but {repo_path} is not in the repository.")
    kind = "tree" if os.path.isdir(full) else "blob"
    target = f"{_state['repo']}/{kind}/main" + ("" if repo_path == "." else f"/{repo_path}")
    return target + sep + frag


class _LinkTree(Treeprocessor):
    def run(self, root):
        for el in root.iter():
            if el.tag == "a" and el.get("href"):
                el.set("href", _rewrite(el.get("href")))
            elif el.tag == "img" and el.get("src"):
                el.set("src", _rewrite(el.get("src")))
            elif el.tag in ("td", "th"):
                for code in el.iter("code"):
                    if code.text:
                        code.text = code.text.replace("\\|", "|")


class _RepoLinks(Extension):
    def extendMarkdown(self, md):
        # after the inline patterns (20), before MkDocs' relative links and checks (0)
        md.treeprocessors.register(_LinkTree(md), "repo_links", 15)


# --- lists ------------------------------------------------------------------------------

_FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})")
_MARKER = re.compile(r"^( *)([-*+]|\d{1,9}[.)])( +|$)")
_BLOCK_START = re.compile(r"^ *(#{1,6} |>|<|\||```|~~~|[-*_]{3,}\s*$)")


def _lists(text):
    """CommonMark list indentation to Python-Markdown's 4 spaces per level."""
    out = []
    stack = []  # (source content column, output content column)
    fence = None  # (marker, source indent of the container, shift)
    prev_blank, prev_list, prev_marker, prev_depth = True, False, False, 0
    for line in text.split("\n"):
        if fence:
            marker, base, shift = fence
            lead = len(line) - len(line.lstrip(" "))
            out.append(_shift(line, shift, base) if lead >= base else line)
            s = line.strip()
            if s.startswith(marker[0] * len(marker)) and not s.lstrip(marker[0]):
                fence = None
            prev_blank = prev_marker = False
            continue
        if not line.strip():
            out.append(line)
            prev_blank, prev_marker = True, False
            continue
        lead = len(line) - len(line.lstrip(" "))
        m = _MARKER.match(line)
        lazy = not m and not prev_blank and prev_list and stack and lead < stack[-1][0] and not _BLOCK_START.match(line)
        if lazy:  # a paragraph's lazy continuation line
            out.append(line)
            prev_blank = prev_marker = False
            continue
        while stack and lead < stack[-1][0]:
            stack.pop()
        src_base, dst_base = stack[-1] if stack else (0, 0)
        if m:
            # Python-Markdown starts a list, an item after a paragraph, or an item of an outer
            # list, only after a blank line
            if not prev_blank and (not prev_marker or len(stack) < prev_depth):
                out.append("")
            dst_marker = dst_base
            content = lead + len(m.group(2)) + max(len(m.group(3)), 1)
            out.append(" " * dst_marker + line.lstrip(" "))
            stack.append((content, dst_marker + 4))
            prev_list = prev_marker = True
            prev_depth = len(stack) - 1
        else:
            shift = dst_base - src_base
            out.append(_shift(line, shift, src_base) if stack else line)
            f = _FENCE.match(line)
            if f:
                fence = (f.group(2), src_base, shift if stack else 0)
            prev_list, prev_marker = bool(stack), False
        prev_blank = False
    return "\n".join(out)


def _shift(line, shift, base):
    if shift >= 0:
        return " " * shift + line
    lead = len(line) - len(line.lstrip(" "))
    return line[min(-shift, lead):]


# --- <details> --------------------------------------------------------------------------

_DETAILS = re.compile(r"^<details>\s*<summary>(.*?)</summary>\s*$")


def _details(text):
    out = []
    lines = text.split("\n")
    i = 0
    fence = None
    while i < len(lines):
        line = lines[i]
        f = _FENCE.match(line)
        if fence:
            if f and f.group(2)[0] == fence[0] and len(f.group(2)) >= len(fence):
                fence = None
            out.append(line)
        elif f:
            fence = f.group(2)
            out.append(line)
        elif _DETAILS.match(line):
            title = _DETAILS.match(line).group(1)
            title = re.sub(r"<code>(.*?)</code>", r"`\1`", title).replace('"', "&quot;")
            out.append(f'??? note "{title}"')
            i += 1
            while i < len(lines) and lines[i].strip() != "</details>":
                out.append("    " + lines[i] if lines[i].strip() else "")
                i += 1
        else:
            out.append(line)
        i += 1
    return "\n".join(out)
