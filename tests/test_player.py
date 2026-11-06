"""What mpv actually plays for each setting: python3 tests/test_player.py

Runs the real mpv profile and script with no video output and tiny generated
clips in a throwaway home, so no window opens and real clips are never read.
"""

import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class PlayerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.home.cleanup)
        cls.data = Path(cls.home.name) / "data"
        cls.state = Path(cls.home.name) / "state"
        videos = cls.data / "videos"
        videos.mkdir(parents=True)
        cls.state.mkdir()
        cls.clips = {"sea-1.mov": "Space", "city-2.mov": "Cities", "reef-3.mov": "Underwater"}
        # Stands in for bin/aerial, to see what the player tells the lock screen.
        cls.cli_log = Path(cls.home.name) / "cli.log"
        cls.cli = Path(cls.home.name) / "fake-aerial"
        cls.cli.write_text(f'#!/bin/sh\necho "$@" >> "{cls.cli_log}"\n')
        cls.cli.chmod(0o755)
        for name in cls.clips:
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=black:s=64x36:d=20:r=10",
                            "-c:v", "mpeg4", "-y", str(videos / name)], check=True, timeout=60)
        (cls.data / "catalog.json").write_text(json.dumps({"clips": {
            name: {"label": name, "category": category, "pois": {"0": "Caption"}} for name, category in cls.clips.items()}}))

    def play(self, config="", extra_opts=""):
        """Starts the player, returns its playlist and first file, then stops it."""
        config_path = Path(self.home.name) / "aerial.conf"
        config_path.write_text(config)
        socket_path = str(Path(self.home.name) / "ipc.sock")
        opts = f"aerial-data={self.data},aerial-state={self.state},aerial-config={config_path},aerial-seed=7{extra_opts}"
        player = subprocess.Popen(
            ["mpv", f"--config-dir={ROOT}/mpv", "--vo=null", "--force-window=no", "--fullscreen=no",
             f"--script-opts={opts}", f"--input-ipc-server={socket_path}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(player.kill)
        try:
            ipc = self.connect(socket_path)
            # A filename appears before the file has loaded, and the script reacts
            # to it loading, so wait for real playback and give the script a moment.
            # Otherwise a check that something did not happen proves nothing.
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and self.get(ipc, "time-pos") is None:
                time.sleep(0.05)
            self.assertIsNotNone(self.get(ipc, "time-pos"), "playback never started")
            time.sleep(0.4)
            return {"file": self.get(ipc, "filename"), "count": self.get(ipc, "playlist-count"),
                    "clock": self.get(ipc, "user-data/aerial/clock")}
        finally:
            player.terminate()
            player.wait(timeout=10)

    def connect(self, path):
        for _ in range(200):
            try:
                client = socket.socket(socket.AF_UNIX)
                client.connect(path)
                client.settimeout(5)
                return client.makefile("rwb", buffering=0)
            except OSError:
                time.sleep(0.05)
        self.fail("mpv did not open its IPC socket")

    def get(self, ipc, prop):
        ipc.write(json.dumps({"command": ["get_property", prop], "request_id": 1}).encode() + b"\n")
        while True:
            reply = json.loads(ipc.readline())
            if reply.get("request_id") == 1:
                return reply.get("data")

    def test_cycle_plays_everything_on_disk(self):
        self.assertEqual(self.play()["count"], 3)

    def test_cycle_can_be_limited_to_a_category(self):
        played = self.play("categories=Cities\n")
        self.assertEqual((played["file"], played["count"]), ("city-2.mov", 1))

    def test_keep_one_plays_only_that_clip(self):
        played = self.play("mode=one\nclip=reef-3.mov\n")
        self.assertEqual((played["file"], played["count"]), ("reef-3.mov", 1))

    def test_a_kept_clip_that_is_missing_falls_back_to_cycling(self):
        self.assertEqual(self.play("mode=one\nclip=gone-9.mov\n")["count"], 3)

    def test_a_preview_overrides_the_settings_file(self):
        played = self.play("mode=cycle\n", ",aerial-mode=one,aerial-clip=sea-1.mov")
        self.assertEqual((played["file"], played["count"]), ("sea-1.mov", 1))

    def cli_calls(self):
        # The call is detached, so give it a moment to land.
        for _ in range(100):
            if self.cli_log.exists():
                break
            time.sleep(0.02)
        return self.cli_log.read_text().splitlines() if self.cli_log.exists() else []

    def test_the_lock_screen_is_told_what_is_playing(self):
        self.cli_log.unlink(missing_ok=True)
        played = self.play("mode=one\nclip=reef-3.mov\n", f",aerial-cli={self.cli}")
        self.assertEqual(self.cli_calls(), [f"lock follow {played['file']}"])

    def test_a_preview_does_not_change_the_lock_screen(self):
        self.cli_log.unlink(missing_ok=True)
        played = self.play("mode=cycle\n", f",aerial-cli={self.cli},aerial-mode=one,aerial-clip=sea-1.mov,aerial-preview=yes")
        self.assertEqual(played["file"], "sea-1.mov")
        self.assertFalse(self.cli_log.exists())

    def assert_clock(self, clock, pattern):
        # Either side of the run, in case the minute turns over during it.
        options = {time.strftime(pattern), time.strftime(pattern, time.localtime(time.time() - 60))}
        self.assertIn(clock, {option.lstrip("0") if pattern.startswith("%I") else option for option in options})

    def test_the_clock_follows_the_system_format(self):
        self.assert_clock(self.play("", ",aerial-clock_format=24h")["clock"], "%H:%M")
        self.assert_clock(self.play("", ",aerial-clock_format=12h")["clock"], "%I:%M")

    def test_older_clock_settings_just_mean_on(self):
        self.assert_clock(self.play("clock=12h\n", ",aerial-clock_format=24h")["clock"], "%H:%M")

    def test_the_clock_can_be_off(self):
        self.assertFalse(self.play("clock=off\n", ",aerial-clock_format=24h")["clock"])

    def test_keep_one_leaves_the_rotation_history_alone(self):
        recent = self.state / "recent"
        recent.write_text("city-2.mov\n")
        self.play("mode=one\nclip=reef-3.mov\n")
        self.assertEqual(recent.read_text(), "city-2.mov\n")


if __name__ == "__main__":
    unittest.main(verbosity=1)
