"""`aerial lock` against a stand-in for the shell's lock IPC: python3 tests/test_lock.py

Nothing here reaches the real lock screen. A fake omarchy-shell goes first on PATH
for each command, and its state lives in a throwaway home.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

AERIAL = Path(__file__).resolve().parent.parent / "bin/aerial"

FAKE_SHELL = """#!/bin/bash
# Answers like the lock service: Lock Screen Explorer, or the stock lock if $FAKE_STOCK is set.
state=$FAKE_STATE
[[ -n ${FAKE_DOWN:-} ]] && exit 1
if [[ $2 == hourFormat ]]; then
  [[ -n ${FAKE_HOUR:-} ]] && { echo "$FAKE_HOUR"; exit 0; }
  echo 'Target not found.'; exit 1
fi
[[ $1 == lock ]] || exit 1
echo "$*" >>"$state/calls"
case $2 in
  status) [[ -n ${FAKE_STOCK:-} ]] && echo '{"locked": false}' || echo "{\\"multimedia\\": ${FAKE_MULTIMEDIA:-true}}" ;;
  design) [[ -n ${FAKE_STOCK:-} ]] && { echo 'Function not found.'; exit 1; }; cat "$state/design" ;;
  video) [[ -n ${FAKE_STOCK:-} ]] && { echo 'Function not found.'; exit 1; }; cat "$state/video" ;;
  setVideo) printf '%s' "$3" >"$state/video"; echo ok ;;
  clearVideo) printf 'none' >"$state/video"; echo ok ;;
esac
"""


class LockTests(unittest.TestCase):
    def setUp(self):
        self.home_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.home_dir.cleanup)
        self.home = Path(self.home_dir.name)
        self.videos = self.home / "data/aerial/videos"
        self.videos.mkdir(parents=True)
        self.state = self.home / "state/aerial"
        self.state.mkdir(parents=True)
        self.config = self.home / "config/aerial/aerial.conf"
        self.config.parent.mkdir(parents=True)
        self.fake = self.home / "fake"
        self.fake.mkdir()
        (self.fake / "design").write_text("my-motion3")
        (self.fake / "video").write_text("none")
        (self.fake / "calls").write_text("")
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        shell = bin_dir / "omarchy-shell"
        shell.write_text(FAKE_SHELL)
        shell.chmod(0o755)
        self.designs = self.home / ".config/omarchy/lock-designs"
        self.designs.mkdir(parents=True)
        (self.designs / "Motion3.qml").write_text("DesignBase { VideoWallpaper { lock: lock } }\n")
        (self.designs / "Sheet.qml").write_text("DesignBase { Wallpaper { lock: lock } }\n")
        self.builtin = self.home / ".config/omarchy/plugins/io.github.sirjul1337.lock-explorer/designs"
        self.builtin.mkdir(parents=True)
        (self.builtin / "Motion.qml").write_text("DesignBase { VideoWallpaper { } }\n")
        (self.builtin / "Classic.qml").write_text("DesignBase { }\n")
        for name in ("a-1.mov", "b-2.mov"):
            (self.videos / name).write_bytes(b"x")
        self.env = {**os.environ, "HOME": str(self.home), "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "XDG_DATA_HOME": str(self.home / "data"), "XDG_STATE_HOME": str(self.home / "state"),
                    "XDG_CONFIG_HOME": str(self.home / "config"), "FAKE_STATE": str(self.fake)}

    def aerial(self, *args, **env):
        return subprocess.run([str(AERIAL), "lock", *args], env={**self.env, **env}, capture_output=True, text=True, timeout=20)

    def status(self, **env):
        return json.loads(self.aerial("status", **env).stdout)

    def video(self):
        return (self.fake / "video").read_text()

    def clip(self, name):
        return str(self.videos / name)

    # ---- when the toggle shows

    def test_available_with_a_video_design_of_your_own(self):
        self.assertTrue(self.status()["available"])

    def test_available_with_the_built_in_motion_design(self):
        (self.fake / "design").write_text("motion")
        self.assertTrue(self.status()["available"])

    def test_not_available_with_a_design_that_has_no_video(self):
        for design in ("my-sheet", "classic", "no-such-design"):
            (self.fake / "design").write_text(design)
            self.assertFalse(self.status()["available"], design)

    def test_not_available_on_the_stock_lock(self):
        status = self.status(FAKE_STOCK="1")
        self.assertFalse(status["available"])
        self.assertFalse(status["enabled"])

    def test_not_available_without_the_video_module(self):
        self.assertFalse(self.status(FAKE_MULTIMEDIA="false")["available"])

    def test_not_available_with_no_shell_running(self):
        status = self.status(FAKE_DOWN="1")
        self.assertFalse(status["available"])
        self.assertFalse(status["enabled"])

    # ---- the clock's format, which the player gets from here

    def hour_format(self, locale_format="", **env):
        bin_dir = self.home / "bin"
        (bin_dir / "locale").write_text(f"#!/bin/sh\necho '{locale_format}'\n")
        (bin_dir / "locale").chmod(0o755)
        return subprocess.run([str(AERIAL), "hour-format"], env={**self.env, **env}, capture_output=True, text=True, timeout=20).stdout.strip()

    def test_the_shell_decides_the_clock_format(self):
        self.assertEqual(self.hour_format("%r", FAKE_HOUR="24h"), "24h")
        self.assertEqual(self.hour_format("%H:%M:%S", FAKE_HOUR="12h"), "12h")

    def test_the_system_locale_decides_without_the_shell(self):
        self.assertEqual(self.hour_format("%r"), "12h")
        self.assertEqual(self.hour_format("%H:%M:%S"), "24h")
        self.assertEqual(self.hour_format("%r", FAKE_DOWN="1"), "12h")

    def test_a_strange_answer_from_the_shell_is_ignored(self):
        self.assertEqual(self.hour_format("%H:%M:%S", FAKE_HOUR="soon"), "24h")

    # ---- on and off

    def test_on_plays_the_kept_clip(self):
        self.config.write_text("mode=one\nclip=b-2.mov\n")
        self.assertEqual(self.aerial("on").returncode, 0)
        self.assertEqual(self.video(), self.clip("b-2.mov"))
        self.assertTrue(self.status()["enabled"])

    def test_on_while_cycling_uses_what_last_played(self):
        (self.state / "recent").write_text("a-1.mov\nb-2.mov\n")
        self.aerial("on")
        self.assertEqual(self.video(), self.clip("b-2.mov"))

    def test_on_with_no_clips_fails_and_changes_nothing(self):
        for path in self.videos.iterdir():
            path.unlink()
        self.assertEqual(self.aerial("on").returncode, 1)
        self.assertEqual(self.video(), "none")

    def test_off_clears_when_there_was_no_video_before(self):
        self.aerial("on")
        self.aerial("off")
        self.assertEqual(self.video(), "none")

    def test_off_puts_back_the_users_own_video(self):
        mine = self.home / "mine.mp4"
        mine.write_bytes(b"x")
        (self.fake / "video").write_text(str(mine))
        self.aerial("on")
        self.assertEqual(self.video(), self.clip("a-1.mov"))
        self.aerial("off")
        self.assertEqual(self.video(), str(mine))

    def test_turning_on_twice_still_restores_the_original(self):
        mine = self.home / "mine.mp4"
        mine.write_bytes(b"x")
        (self.fake / "video").write_text(str(mine))
        self.aerial("on")
        self.aerial("on")
        self.aerial("off")
        self.assertEqual(self.video(), str(mine))

    def test_off_leaves_a_video_chosen_in_explorer_alone(self):
        self.aerial("on")
        mine = self.home / "other.mp4"
        mine.write_bytes(b"x")
        (self.fake / "video").write_text(str(mine))
        self.assertFalse(self.status()["enabled"])
        self.aerial("off")
        self.assertEqual(self.video(), str(mine))

    # ---- keeping up with the screensaver and the library

    def test_follow_tracks_the_screensaver_while_on(self):
        self.aerial("on")
        self.aerial("follow", "b-2.mov")
        self.assertEqual(self.video(), self.clip("b-2.mov"))

    def test_follow_does_nothing_while_off(self):
        self.aerial("follow", "b-2.mov")
        self.assertEqual(self.video(), "none")

    def test_follow_does_not_replace_a_video_chosen_in_explorer(self):
        mine = self.home / "mine.mp4"
        mine.write_bytes(b"x")
        (self.fake / "video").write_text(str(mine))
        self.aerial("follow", "b-2.mov")
        self.assertEqual(self.video(), str(mine))

    def test_follow_ignores_anything_but_a_clip_here(self):
        self.aerial("on")
        before = self.video()
        for name in ("../../secret.mov", "/etc/passwd", "missing.mov", ""):
            self.aerial("follow", name)
            self.assertEqual(self.video(), before, name)

    def test_sync_moves_to_a_newly_kept_clip(self):
        self.aerial("on")
        self.config.write_text("mode=one\nclip=b-2.mov\n")
        self.aerial("sync")
        self.assertEqual(self.video(), self.clip("b-2.mov"))

    def test_sync_replaces_a_deleted_clip(self):
        self.aerial("on")
        current = Path(self.video())
        current.unlink()
        self.aerial("sync")
        self.assertNotEqual(self.video(), str(current))
        self.assertTrue(Path(self.video()).exists())

    def test_sync_lets_go_when_no_clips_are_left(self):
        self.aerial("on")
        for path in self.videos.iterdir():
            path.unlink()
        self.aerial("sync")
        self.assertEqual(self.video(), "none")

    def test_sync_does_nothing_while_off(self):
        self.config.write_text("mode=one\nclip=b-2.mov\n")
        self.aerial("sync")
        self.assertEqual(self.video(), "none")
        self.assertNotIn("setVideo", (self.fake / "calls").read_text())

    def test_sync_does_not_write_when_nothing_changed(self):
        self.aerial("on")
        (self.fake / "calls").write_text("")
        self.aerial("sync")
        self.assertNotIn("setVideo", (self.fake / "calls").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
