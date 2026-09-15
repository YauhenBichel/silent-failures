# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
"""firmware-drift against a fake upstream: no network."""

import importlib.machinery
import importlib.util
import io
import json
import lzma
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin" / "firmware-drift"
_loader = importlib.machinery.SourceFileLoader("firmware_drift", str(BIN))
_spec = importlib.util.spec_from_loader("firmware_drift", _loader)
fd = importlib.util.module_from_spec(_spec)
sys.modules["firmware_drift"] = fd  # dataclasses look their module up while the file runs
_loader.exec_module(fd)

NAME = "amdgpu/gc_11_5_1_mes_2.bin"
VERSIONS = [  # newest first: commit, date, content at that commit
    ("c" * 40, "2026-09-11", b"version three"),
    ("b" * 40, "2026-08-10", b"version two"),
    ("a" * 40, "2026-02-25", b"version one"),
]


class FakeUpstream(fd.Upstream):
    def __init__(self, versions=VERSIONS, cache=None):
        self.versions = versions
        self.urls = []
        super().__init__(get=self.fetch, cache=cache)

    def fetch(self, url):
        self.urls.append(url)
        if "/repository/commits?" in url:
            return json.dumps([{"id": c, "committed_date": d + "T10:00:00.000+00:00", "title": "amdgpu: update"}
                               for c, d, _ in self.versions]).encode()
        for commit, _, data in self.versions:
            if url.endswith("ref=" + commit):
                if data is None:
                    raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
                return data
        raise AssertionError(f"unexpected URL {url}")


class FirmwareDrift(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.base = self.tmp / "lib" / "firmware"
        self.dirs = [self.base / "updates" / "7.0.0", self.base / "updates", self.base / "7.0.0", self.base]

    def install(self, data, suffix="", where=None):
        path = (where or self.base) / (NAME + suffix)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(lzma.compress(data) if suffix == ".xz" else data)
        return path

    def run_main(self, *argv, upstream=None):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = fd.main(list(argv), upstream=upstream or FakeUpstream(), dirs=self.dirs)
        return code, out.getvalue(), err.getvalue()

    def test_current(self):
        self.install(b"version three")
        code, out, _ = self.run_main(NAME)
        self.assertEqual(code, 0)
        self.assertIn("none: current", out)

    def test_behind_names_the_match_and_what_is_newer(self):
        self.install(b"version one")
        code, out, _ = self.run_main(NAME)
        self.assertEqual(code, 1)
        self.assertIn(f"{'a' * 12} 2026-02-25", out)
        self.assertIn(f"2, the newest {'c' * 12} 2026-09-11", out)

    def test_stops_at_the_first_match(self):
        self.install(b"version two")
        upstream = FakeUpstream()
        self.run_main(NAME, upstream=upstream)
        self.assertFalse(any(u.endswith("ref=" + "a" * 40) for u in upstream.urls))

    def test_content_upstream_never_had(self):
        self.install(b"patched locally")
        code, out, _ = self.run_main(NAME)
        self.assertEqual(code, 2)
        self.assertIn("no match in 3", out)

    def test_xz_is_decompressed(self):
        self.install(b"version two", suffix=".xz")
        code, out, _ = self.run_main(NAME, "--json")
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)[0]["installed"]["commit"], "b" * 40)

    @unittest.skipUnless(shutil.which("zstd"), "zstd is not installed")
    def test_zst_is_decompressed(self):
        raw = self.install(b"version three")
        subprocess.run(["zstd", "-q", "--rm", str(raw), "-o", str(raw) + ".zst"], check=True)
        code, _, _ = self.run_main(NAME)
        self.assertEqual(code, 0)

    def test_an_installed_path_is_named_as_the_kernel_names_it(self):
        path = self.install(b"version three", suffix=".xz", where=self.base / "updates")
        code, out, _ = self.run_main(str(path))
        self.assertEqual(code, 0)
        self.assertIn(NAME, out)

    def test_the_kernel_search_order(self):
        self.install(b"x", suffix=".xz", where=self.base / "updates")
        plain_base = self.install(b"y")
        self.assertEqual(fd.find_installed(NAME, self.dirs), plain_base)  # uncompressed anywhere comes first
        plain_updates = self.install(b"z", where=self.base / "updates")
        self.assertEqual(fd.find_installed(NAME, self.dirs), plain_updates)  # and updates/ before the base

    def test_a_version_missing_upstream_is_skipped(self):
        self.install(b"version one")
        versions = [VERSIONS[0], (VERSIONS[1][0], VERSIONS[1][1], None), VERSIONS[2]]
        code, out, _ = self.run_main(NAME, upstream=FakeUpstream(versions))
        self.assertEqual(code, 1)
        self.assertIn(f"{'a' * 12} 2026-02-25", out)

    def test_hashes_are_cached(self):
        self.install(b"version one")
        cache = self.tmp / "cache"
        self.run_main(NAME, upstream=FakeUpstream(cache=cache))
        second = FakeUpstream(cache=cache)
        self.run_main(NAME, upstream=second)
        self.assertEqual([u for u in second.urls if "/raw?" in u], [])

    def test_a_named_file_that_is_not_installed(self):
        code, _, err = self.run_main(NAME)
        self.assertEqual(code, 2)
        self.assertIn("is not installed", err)

    def test_match_filters_names(self):
        self.install(b"version three")
        code, out, _ = self.run_main(NAME, "--match", "vpe_")
        self.assertEqual(code, 2)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
