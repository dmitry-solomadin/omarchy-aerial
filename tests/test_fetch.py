"""The fetcher's offline commands, run in a throwaway home: python3 tests/test_fetch.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

FETCH = Path(__file__).resolve().parent.parent / "lib/aerial-fetch.py"


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        root = Path(self.home.name)
        self.videos = root / "data/aerial/videos"
        self.thumbs = root / "cache/aerial/thumbnails"
        self.videos.mkdir(parents=True)
        self.thumbs.mkdir(parents=True)
        self.env = {**os.environ, "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache")}

    def fetch(self, *args):
        return subprocess.run([sys.executable, "-I", str(FETCH), *args], env=self.env, capture_output=True, text=True, timeout=30)

    def events(self, result):
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_library_reports_clips_and_skips_partial_and_foreign_files(self):
        (self.videos / "sea-1.mov").write_bytes(b"12345")
        (self.videos / "city-2.mov.part").write_bytes(b"123")
        (self.videos / "my holiday.mov").write_bytes(b"1")
        (self.thumbs / "sea-1.mov.jpg").write_bytes(b"x")
        report = json.loads(self.fetch("--library").stdout)
        self.assertEqual(report["clips"], {"sea-1.mov": 5})
        self.assertEqual(report["thumbnails"], ["sea-1.mov.jpg"])
        self.assertGreater(report["free"], 0)
        self.assertIsNone(report["catalogAge"])

    def test_delete_removes_the_clip_partial_and_frame_but_keeps_the_preview(self):
        for path in (self.videos / "sea-1.mov", self.videos / "sea-1.mov.part", self.thumbs / "sea-1.mov.jpg",
                     self.thumbs / "sea-1.mov.png", self.videos / "city-2.mov"):
            path.write_bytes(b"x")
        result = self.fetch("--delete", "sea-1.mov", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.events(result), [{"event": "deleted", "clip": "sea-1.mov"}])
        self.assertFalse((self.videos / "sea-1.mov").exists())
        self.assertFalse((self.videos / "sea-1.mov.part").exists())
        self.assertFalse((self.thumbs / "sea-1.mov.jpg").exists())
        self.assertTrue((self.thumbs / "sea-1.mov.png").exists())
        self.assertTrue((self.videos / "city-2.mov").exists())

    def test_delete_refuses_anything_but_a_clip_name(self):
        outside = Path(self.home.name) / "important.mov"
        outside.write_bytes(b"x")
        for name in ("../../../important.mov", "/etc/passwd", "sea.mp4", "..", "a/b.mov"):
            result = self.fetch(f"--delete={name}", "--json")
            self.assertEqual(result.returncode, 1, name)
            self.assertEqual(self.events(result)[0]["event"], "error", name)
        self.assertTrue(outside.exists())

    def test_downloading_a_clip_outside_the_catalogue_is_an_error_not_a_request(self):
        data = Path(self.env["XDG_DATA_HOME"]) / "aerial"
        (data / "catalog.json").write_text(json.dumps({"clips": {}}))
        result = self.fetch("--clip", "sea-1.mov", "--json")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.events(result)[0]["event"], "error")

    def test_a_clip_already_on_disk_downloads_nothing(self):
        data = Path(self.env["XDG_DATA_HOME"]) / "aerial"
        (data / "catalog.json").write_text(json.dumps({"clips": {"sea-1.mov": {"label": "Sea", "url": "https://invalid.example/x", "size": 1}}}))
        (self.videos / "sea-1.mov").write_bytes(b"x")
        result = self.fetch("--clip", "sea-1.mov", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.events(result), [{"event": "done", "clip": "sea-1.mov"}])

    def test_only_apple_urls_are_ever_requested(self):
        data = Path(self.env["XDG_DATA_HOME"]) / "aerial"
        (data / "catalog.json").write_text(json.dumps({"clips": {"sea-1.mov": {"label": "Sea", "url": "https://evil.example/x", "size": 1}}}))
        result = self.fetch("--clip", "sea-1.mov", "--json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing non-Apple URL", self.events(result)[0]["message"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
