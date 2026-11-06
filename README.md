# Aerial

An Apple TV style aerial video screensaver for [Omarchy](https://omarchy.org). It
replaces the terminal text effects with slow 4K footage, a clock, and Apple's
location captions, and it comes with a window for choosing what plays. The window
is a shell plugin, so it follows your theme, fonts and scaling live.

## Install

Requires Omarchy's Quickshell-based shell, `mpv`, `python3`, `ffmpeg`, `socat` and `jq`.

```bash
git clone https://github.com/dmitry-solomadin/omarchy-aerial
cd omarchy-aerial
./install
```

That links this folder as a shell plugin, so keep it where it is. It also makes Aerial
the Omarchy screensaver and adds the shortcuts. Then open the window to download some
clips. `./uninstall` undoes all of it and keeps downloaded clips.

| Shortcut | |
|---|---|
| `Super+Alt+A` | Open the Aerial window, also in the launcher as **Aerial** |
| `Super+Alt+Z` | Start the screensaver now |

## The window

Browse Apple's catalogue, download or delete individual clips, and choose between
cycling through what's downloaded or looping one clip. It opens as a floating window,
since it's a quick stop rather than somewhere to stay. Downloads carry on after it closes. Changes save on their own and apply the next time the screensaver starts.

## On the lock screen

Only a lock screen may draw while the session is locked, so the screensaver can't play
over one. If [Lock Screen Explorer](https://github.com/SirJul1337/omarchy-lock-explorer)
is running and your active lock design can show video, such as Motion, the window offers
**Play clips on the lock screen**. Without those, Aerial works the same and the option
doesn't appear.

It plays one clip on a loop while locked: the clip you set to loop, or the one the screensaver
last showed. Turning it off puts back any video you had before. A video you choose in Explorer
is left alone. Display blanking stays Explorer's setting, so a lock that never blanks keeps
playing, and using the GPU, until you return.

## From the command line

```bash
aerial fetch --budget 20G     # download clips up to a total size, or --all for 50 GB
aerial start force            # start it now, any key or mouse movement ends it
aerial status
aerial lock status            # or on, off
```

The clock's 12 or 24 hours follows Omarchy's language setting, as its own panels do.

Settings are in `~/.config/aerial/aerial.conf`, which keeps any comments you add. Clips
are in `~/.local/share/aerial/videos`, and any other video you put there joins the
rotation, without captions.

The window checks Apple's catalogue when it first opens each session if the copy here
is over a week old. It fetches missing thumbnails at the same time. Nothing reaches the
network while the window has never been opened, or unless you start a download.

## How it fits into Omarchy

Omarchy's idle service runs `omarchy-launch-screensaver` through a login shell, and
tracks the screensaver by its window class. Aerial keeps that contract rather than
replacing the idle service:

- A small shim named `omarchy-launch-screensaver` goes first on the login shell `PATH`,
  using one marked block in `~/.bash_profile`. No file under `/usr` is changed.
- The player is an mpv window with the class `org.omarchy.screensaver`, so the stock
  window rules, idle timers, and the `pkill` in `omarchy-system-lock` all work unchanged.
  The Omarchy screensaver toggle still applies.
- With no clips, without mpv, or if no window opens, it falls back to the stock screensaver.

mpv runs with its own config directory, `mpv/`, so your `~/.config/mpv` is neither read
nor affected.

## Clips

The catalogue and clips come from Apple's public CDN. They are Apple's copyrighted
footage, downloaded to this machine and not part of this project. Apple's published
license terms don't grant permission for this use, so don't redistribute them.

`sylvan.apple.com` chains to Apple's own root certificate, which is not in the system
trust store. `certs/apple-root-ca.pem` is that root, and the fetcher trusts it for that
host only. Certificate verification stays on.

The clips are 4K HEVC at 240 fps with temporal layers, and mpv drops the top layer to
play them at 120 fps. Transitions are a dip to black, since a true crossfade would need
a second decoder running.

## Development

```text
qml/            the shell plugin: Service, window, store, and the rules in Library.js
bin/aerial      the command: starts the screensaver, installs, and runs the fetcher
lib/            the fetcher, the only code that touches the network
mpv/            the player's isolated mpv profile and overlay script
tests/          regression tests, and render/ to picture the window
```

`bin/test` runs the regression tests. None of them open a window or need the network.

After changing QML, run `omarchy restart shell` to see it live. Saving doesn't reliably
reach a plugin linked into the plugins folder, and the store is a singleton that lasts
as long as the shell does.

`tests/render/run <folder>` saves pictures of the real window in each state and reports
hover behavior, offscreen with Omarchy's real kit and the current theme, in a throwaway
home. Its pointer events go to that offscreen window and can't reach the desktop.

A running window can be read and pressed as text, without sending key presses:

```bash
omarchy-shell io.github.dmitry-solomadin.aerial status
omarchy-shell io.github.dmitry-solomadin.aerial dump ""
omarchy-shell io.github.dmitry-solomadin.aerial activate startScreensaver
omarchy-shell io.github.dmitry-solomadin.aerial choose modeChoice one
```
