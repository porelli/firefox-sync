#!/usr/bin/env python3
"""Unit tests of .github/scripts/syncstorage-rs-build.py: the cache mounts it drops from
upstream's Dockerfile, on fixtures, no network.

Usage: python3 tests/test_syncstorage_rs_build.py [-v]
"""

import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("syncstorage_rs_build", os.path.join(ROOT, ".github", "scripts", "syncstorage-rs-build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

# as upstream's Dockerfile has them (0.24.0)
UPSTREAM = """COPY --from=planner /app/recipe.json recipe.json

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \\
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \\
    --mount=type=cache,target=/app/target,sharing=locked \\
    set -x && \\
    cargo chef cook --release --recipe-path recipe.json

RUN --mount=type=cache,target=/app/target,sharing=locked \\
    cargo install --path ./syncserver --locked --root /app
"""


class DropCacheMounts(unittest.TestCase):
    def test_upstream(self):
        text, count = build.drop_cache_mounts(UPSTREAM)
        self.assertEqual(count, 4)
        self.assertEqual(text, """COPY --from=planner /app/recipe.json recipe.json

RUN set -x && \\
    cargo chef cook --release --recipe-path recipe.json

RUN cargo install --path ./syncserver --locked --root /app
""")

    def test_same_line_and_field_order(self):
        text, count = build.drop_cache_mounts("RUN --mount=target=/app/target,type=cache cargo build\n")
        self.assertEqual((text, count), ("RUN cargo build\n", 1))

    def test_other_mounts_kept(self):
        line = "RUN --mount=type=secret,id=token --mount=type=bind,source=x,target=/x make\n"
        self.assertEqual(build.drop_cache_mounts(line), (line, 0))
        self.assertEqual(build.drop_cache_mounts("RUN --mount=type=cache,target=/c --mount=type=secret,id=t make\n"),
                         ("RUN --mount=type=secret,id=t make\n", 1))


if __name__ == "__main__":
    unittest.main()
