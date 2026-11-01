#!/usr/bin/env python3
"""Prepares the checkout of a syncstorage-rs release for the build of syncstorage-rs.yml.

Usage: syncstorage-rs-build.py <source-checkout-dir>

After the upstream patches, before docker build; the same for every backend and architecture.
This file is in the key of the images the workflow reuses: a change of it builds them again.

- version.json: what upstream's CI fills in (served at /__version__, "TBD" otherwise), from
  SERVICE_TAG, SERVICE_REPOSITORY_NAME and BUILD_URL, and the checkout's commit.
- The Dockerfile's cache mounts (RUN --mount=type=cache: cargo's registry and git, /app/target)
  are dropped. Upstream's Dockerfile cooks the dependencies first (cargo-chef, keyed on its
  recipe of the Cargo.lock and manifests), but into those mounts: they are empty on every new
  GitHub runner and no registry cache exports them, so the cooked layer came back from the
  build cache without the compiled dependencies and `cargo install` compiled them all again.
  Without the mounts they are in the layer itself, which the registry cache keeps (mode=max):
  only syncstorage-rs' own crates compile while the recipe is the same. The image is the same
  (only /app/bin and files of the sources leave the builder stage). When upstream's Dockerfile
  has no such mount any more, a ::warning:: and nothing changed.
"""

import json
import os
import re
import subprocess
import sys

# an option of RUN, whatever the order of its fields, and the line continuation after it
CACHE_MOUNT = re.compile(r"--mount=(?=[^\s]*\btype=cache\b)[^\s]+[ \t]*(?:\\\n[ \t]*)?")


def drop_cache_mounts(text):
    """The Dockerfile without its cache mounts, and how many there were."""
    return CACHE_MOUNT.subn("", text)


def main(argv):
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    checkout = argv[0]
    commit = subprocess.run(["git", "-C", checkout, "rev-parse", "HEAD"], check=True,
                            capture_output=True, text=True).stdout.strip()
    version = {"version": os.environ["SERVICE_TAG"], "commit": commit,
               "source": f"https://github.com/{os.environ['SERVICE_REPOSITORY_NAME']}",
               "build": os.environ["BUILD_URL"]}
    with open(os.path.join(checkout, "version.json"), "w") as f:
        f.write(json.dumps(version, separators=(",", ":")) + "\n")
    print(f"version.json: {json.dumps(version, separators=(',', ':'))}")

    path = os.path.join(checkout, "Dockerfile")
    with open(path) as f:
        text, count = drop_cache_mounts(f.read())
    if count == 0:
        print("::warning title=syncstorage-rs-build.py::the Dockerfile has no cache mount (RUN --mount=type=cache) "
              "any more: nothing dropped, check how it caches the compiled dependencies now")
        return 0
    if "type=cache" in text:
        print(f"::error title=syncstorage-rs-build.py::a cache mount of the Dockerfile is left after dropping {count}")
        return 1
    with open(path, "w") as f:
        f.write(text)
    print(f"Dockerfile: {count} cache mounts dropped")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
