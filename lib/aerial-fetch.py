#!/usr/bin/env python3
"""Download Apple's aerial catalogue, its clips, and thumbnails for them."""

import argparse
import fcntl
import functools
import io
import json
import os
import plistlib
import random
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

CONFIG_URL = "https://configuration.apple.com/configurations/internetservices/aerials/resources-config-15-0.plist"
CLIP_HOST = "sylvan.apple.com"
URL_KEYS = ("url-4K-SDR-240FPS", "url-4K-SDR")
USER_AGENT = "aerial-screensaver/0.1"
CHUNK = 1024 * 1024
PROGRESS_INTERVAL = 0.25

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "aerial"
VIDEOS = DATA / "videos"
CATALOG = DATA / "catalog.json"
THUMBNAILS = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "aerial/thumbnails"

CATALOG_NAME = re.compile(r"[a-z0-9][a-z0-9-]*\.mov")

json_output = False


@functools.lru_cache(maxsize=None)
def tls_context(host):
    # sylvan.apple.com chains to Apple's own root, which is not in the system trust
    # store. Trust that root for this one host rather than turning verification off.
    if host == CLIP_HOST:
        return ssl.create_default_context(cafile=str(ROOT / "certs/apple-root-ca.pem"))
    return ssl.create_default_context()


def say(text):
    if not json_output:
        print(text, flush=True)


def emit(event, **fields):
    """Report to the settings app, which reads one JSON object per line."""
    if json_output:
        print(json.dumps({"event": event, **fields}), flush=True)


def request(url, method="GET", headers=None, timeout=60):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname.endswith(".apple.com"):
        raise ValueError(f"refusing non-Apple URL: {url}")
    req = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT, **(headers or {})})
    return urllib.request.urlopen(req, timeout=timeout, context=tls_context(parts.hostname))


def fetch_bytes(url):
    with request(url) as response:
        return response.read()


def language():
    lang = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or "en"
    return lang.split(".")[0].split("_")[0] or "en"


def load_manifest():
    """Read the manifest and caption strings straight from the tar, without unpacking it."""
    resources_url = plistlib.loads(fetch_bytes(CONFIG_URL))["resources-url"]
    tar = tarfile.open(fileobj=io.BytesIO(fetch_bytes(resources_url)))
    members = {member.name.removeprefix("./"): member for member in tar.getmembers() if member.isfile()}

    entries = json.load(tar.extractfile(members["entries.json"]))
    template = "TVIdleScreenStrings.bundle/{}.lproj/Localizable.nocache.strings"
    strings_path = template.format(language())
    if strings_path not in members:
        strings_path = template.format("en")
    strings = plistlib.load(tar.extractfile(members[strings_path]))
    return entries, strings


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "clip"


def build_catalog(entries, strings):
    categories = {c["id"]: c.get("localizedNameKey", "").removeprefix("AerialCategory") for c in entries["categories"]}
    clips = {}
    for asset in entries["assets"]:
        if not asset.get("includeInShuffle", True):
            continue
        url = next((asset[key] for key in URL_KEYS if asset.get(key)), None)
        if not url:
            continue
        label = strings.get(asset.get("localizedNameKey")) or asset.get("accessibilityLabel") or "Aerial"
        filename = f"{slug(label)}-{asset['id'][:8].lower()}.mov"
        clips[filename] = {
            "label": label,
            "category": categories.get((asset.get("categories") or [None])[0], ""),
            "url": url,
            "preview": asset.get("previewImage", ""),
            "pois": {time: strings[key] for time, key in asset.get("pointsOfInterest", {}).items() if key in strings},
        }
    return clips


def clip_size(url):
    with request(url, method="HEAD", timeout=30) as response:
        return int(response.headers["Content-Length"])


def refresh_catalog():
    entries, strings = load_manifest()
    clips = build_catalog(entries, strings)
    with ThreadPoolExecutor(16) as pool:
        sizes = pool.map(lambda clip: clip_size(clip["url"]), clips.values())
        for clip, size in zip(clips.values(), sizes):
            clip["size"] = size

    DATA.mkdir(parents=True, exist_ok=True)
    temporary = CATALOG.with_suffix(".tmp")
    temporary.write_text(json.dumps({"clips": clips}, indent=1, ensure_ascii=False))
    temporary.replace(CATALOG)
    return clips


def read_catalog():
    if CATALOG.exists():
        return json.loads(CATALOG.read_text())["clips"]
    return refresh_catalog()


def choose(clips, budget):
    """Spread the budget evenly across categories.

    The shuffle is deterministic, so raising the budget later adds to what is
    already there instead of choosing a different set.
    """
    shuffler = random.Random("aerial")
    by_category = {}
    for filename in sorted(clips):
        by_category.setdefault(clips[filename]["category"], []).append(filename)
    for names in by_category.values():
        shuffler.shuffle(names)

    # Clips already on disk count first, so a smaller budget never deletes them
    # and never fetches more on top of them.
    chosen = [name for name in clips if (VIDEOS / name).exists()]
    spent = sum(clips[name]["size"] for name in chosen)
    while any(by_category.values()):
        for names in by_category.values():
            while names:
                name = names.pop(0)
                if name in chosen:
                    continue
                if budget is None or spent + clips[name]["size"] <= budget:
                    chosen.append(name)
                    spent += clips[name]["size"]
                    break
    return chosen


def download(filename, clip, on_progress=None):
    target = VIDEOS / filename
    partial = target.with_name(filename + ".part")
    size = clip["size"]

    with open(partial, "ab") as output:
        # The command line and the settings app can both ask for the same clip,
        # and two writers would mangle the file.
        try:
            fcntl.flock(output, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise IOError("it is already being downloaded") from None

        have = output.tell()
        if have > size:
            output.truncate(0)
            have = 0

        if have < size:
            headers = {"Range": f"bytes={have}-"} if have else {}
            with request(clip["url"], headers=headers, timeout=60) as response:
                # A server that ignores the range sends the whole file, so start over.
                if response.status != 206:
                    output.truncate(0)
                    have = 0
                last_report = 0
                while chunk := response.read(CHUNK):
                    output.write(chunk)
                    have += len(chunk)
                    now = time.monotonic()
                    if on_progress and now - last_report >= PROGRESS_INTERVAL:
                        last_report = now
                        on_progress(have, size)
            output.flush()

        if partial.stat().st_size != size:
            raise IOError(f"got {partial.stat().st_size} bytes, expected {size}")
        partial.rename(target)
    return filename


def fetch_preview(name, clip):
    target = THUMBNAILS / (name + ".png")
    if target.exists() or not clip.get("preview"):
        return
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_bytes(fetch_bytes(clip["preview"]))
    temporary.replace(target)


def extract_frame(name):
    """Apple's previews are only 214 pixels wide, so downloaded clips get a sharper one of their own."""
    video = VIDEOS / name
    target = THUMBNAILS / (name + ".jpg")
    if target.exists() or not video.exists():
        return
    temporary = target.with_name(name + ".tmp.jpg")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-skip_frame", "nokey", "-ss", "12", "-i", str(video),
         "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "4", "-y", str(temporary)],
        check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    temporary.replace(target)


def fetch_thumbnails(clips, names):
    THUMBNAILS.mkdir(parents=True, exist_ok=True)

    def fetch_one(name):
        fetch_preview(name, clips[name])
        extract_frame(name)
        return name

    failures = 0
    with ThreadPoolExecutor(6) as pool:
        futures = {pool.submit(fetch_one, name): name for name in names}
        for future in as_completed(futures):
            try:
                emit("thumbnail", clip=future.result())
            except Exception as error:  # a missing thumbnail should not stop the rest
                failures += 1
                print(f"thumbnail failed: {futures[future]}: {error}", file=sys.stderr, flush=True)
    return 1 if failures else 0


def download_named(clips, names):
    """Download exactly these clips, which is what the settings app asks for."""
    VIDEOS.mkdir(parents=True, exist_ok=True)
    failures = 0
    for name in names:
        if name not in clips:
            print(f"not in the catalogue: {name}", file=sys.stderr)
            emit("error", clip=name, message="it is not in the catalogue")
            failures += 1
            continue
        if (VIDEOS / name).exists():
            emit("done", clip=name)
            continue
        try:
            download(name, clips[name], lambda have, total, name=name: emit("progress", clip=name, bytes=have, total=total))
            say(f"Downloaded {clips[name]['label']}")
            emit("done", clip=name)
        except Exception as error:
            print(f"failed: {clips[name]['label']}: {error}", file=sys.stderr, flush=True)
            emit("error", clip=name, message=str(error))
            failures += 1
    return 1 if failures else 0


def report_library():
    """What the Aerial window needs to know about this machine, as one JSON object."""
    VIDEOS.mkdir(parents=True, exist_ok=True)
    clips = {entry.name: entry.stat().st_size for entry in os.scandir(VIDEOS)
             if entry.is_file() and CATALOG_NAME.fullmatch(entry.name)}
    thumbnails = sorted(entry.name for entry in os.scandir(THUMBNAILS)) if THUMBNAILS.exists() else []
    catalog_age = time.time() - CATALOG.stat().st_mtime if CATALOG.exists() else None
    print(json.dumps({
        "clips": clips,
        "thumbnails": thumbnails,
        "free": shutil.disk_usage(VIDEOS).free,
        "catalogAge": catalog_age,
    }), flush=True)
    return 0


def delete_clip(name):
    """Remove a clip, any partial download of it, and the thumbnail cut from it.

    Apple's own preview stays, since the card still needs a picture. The name
    check keeps this inside the videos folder, whatever it is asked to delete.
    """
    if not CATALOG_NAME.fullmatch(name):
        print(f"not a clip name: {name!r}", file=sys.stderr)
        emit("error", clip=name, message="that is not a clip name")
        return 1
    for path in (VIDEOS / name, VIDEOS / (name + ".part"), THUMBNAILS / (name + ".jpg")):
        path.unlink(missing_ok=True)
    emit("deleted", clip=name)
    return 0


def parse_size(text):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([MG]?)B?", text.strip(), re.IGNORECASE)
    if not match:
        raise argparse.ArgumentTypeError(f"expected a size like 20G or 500M, got {text!r}")
    scale = {"": 1, "M": 10**6, "G": 10**9}[match[2].upper()]
    return int(float(match[1]) * scale)


def gigabytes(size):
    return f"{size / 1e9:.1f} GB"


def main():
    global json_output

    parser = argparse.ArgumentParser(prog="aerial fetch", description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--budget", type=parse_size, default=parse_size("20G"), help="total disk use, such as 20G (default)")
    group.add_argument("--all", action="store_true", help="download the whole catalogue")
    parser.add_argument("--clip", action="append", metavar="FILE", help="download only this clip, from the catalogue")
    parser.add_argument("--catalog", action="store_true", help="only refresh the catalogue")
    parser.add_argument("--thumbnails", action="store_true", help="only fetch thumbnails, limited by --clip if given")
    parser.add_argument("--library", action="store_true", help="report what is on disk as JSON")
    parser.add_argument("--delete", metavar="FILE", help="delete one clip from this machine")
    parser.add_argument("--jobs", type=int, default=3, help="parallel downloads (default 3)")
    parser.add_argument("--dry-run", action="store_true", help="show what would be downloaded")
    parser.add_argument("--json", action="store_true", help="report progress as JSON lines")
    args = parser.parse_args()
    json_output = args.json

    if args.library:
        return report_library()

    if args.delete:
        return delete_clip(args.delete)

    if args.catalog:
        clips = refresh_catalog()
        say(f"Catalogue: {len(clips)} clips, {gigabytes(sum(c['size'] for c in clips.values()))}")
        emit("catalog", clips=len(clips))
        return 0

    if args.thumbnails:
        clips = read_catalog()
        return fetch_thumbnails(clips, [name for name in (args.clip or clips) if name in clips])

    if args.clip:
        return download_named(read_catalog(), args.clip)

    VIDEOS.mkdir(parents=True, exist_ok=True)
    say("Reading Apple's catalogue...")
    clips = refresh_catalog()

    chosen = choose(clips, None if args.all else args.budget)
    missing = [name for name in chosen if not (VIDEOS / name).exists()]
    say(f"Catalogue: {len(clips)} clips, {gigabytes(sum(c['size'] for c in clips.values()))}")
    say(f"Selected:  {len(chosen)} clips, {gigabytes(sum(clips[n]['size'] for n in chosen))}")
    say(f"To fetch:  {len(missing)} clips, {gigabytes(sum(clips[n]['size'] for n in missing))}")

    if args.dry_run:
        for name in missing:
            say(f"  {clips[name]['category']:<11} {gigabytes(clips[name]['size']):>7}  {clips[name]['label']}")
        return 0

    failures = 0
    done = 0
    pool = ThreadPoolExecutor(args.jobs)
    futures = {pool.submit(download, name, clips[name]): name for name in missing}
    try:
        for future in as_completed(futures):
            name = futures[future]
            try:
                future.result()
                done += 1
                say(f"[{done}/{len(missing)}] {clips[name]['label']} ({clips[name]['category']})")
            except Exception as error:  # one failed clip should not stop the rest
                failures += 1
                print(f"failed: {clips[name]['label']}: {error}", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)
        print("\nStopped. Run it again to resume.", file=sys.stderr)
        os._exit(130)
    pool.shutdown()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
