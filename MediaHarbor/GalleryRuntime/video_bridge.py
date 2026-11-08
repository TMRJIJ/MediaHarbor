"""Private JSON-lines interface between Media Harbor and yt-dlp."""

from http.cookiejar import Cookie, DefaultCookiePolicy
from contextlib import nullcontext
import itertools
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from time import monotonic
from urllib.parse import urlsplit

RUNTIME = Path(sys.executable).resolve().parents[1]
VIDEO_RUNTIME = RUNTIME.parent / "VideoRuntime"
sys.path.insert(0, str(RUNTIME / "lib" / "python3.13" / "site-packages"))

from yt_dlp import YoutubeDL
from yt_dlp.extractor import gen_extractor_classes
from yt_dlp.globals import plugin_dirs
from yt_dlp.version import __version__
from yt_dlp.utils import DownloadError

PLAYLIST_LIMIT = 250
OUTPUT_EXTENSIONS = {"mp4", "mkv", "webm", "mov", "m4v", "ts", "m4a", "mp3", "ogg", "opus", "flac", "wav", "aac"}
SAFE_HEADERS = {"accept", "accept-language", "origin", "referer", "user-agent"}


def emit(event, **data):
    print(json.dumps({"event": event, **data}, ensure_ascii=True, separators=(",", ":")), flush=True)


def web(url):
    if not isinstance(url, str) or not url or any(c.isspace() for c in url):
        return None
    try:
        value = urlsplit(url)
        if value.scheme in {"http", "https"} and value.hostname and value.username is None:
            return value
    except ValueError:
        pass
    return None


def working_extractors():
    for cls in gen_extractor_classes():
        name = (cls.IE_NAME or cls.ie_key()).partition(":")[0].lower()
        if name not in {"generic", "testurl", "commonmistakes", "commonprotocols"} and cls.working():
            yield cls


def catalog():
    sites = {}
    count = 0
    for cls in working_extractors():
        name = cls.IE_NAME or cls.ie_key()
        group, _, subtype = name.partition(":")
        if not group:
            continue
        count += 1
        identifier = group.lower()
        site = sites.setdefault(identifier, {"id": identifier, "examples": {}, "hosts": set(), "oauth": False})
        if isinstance(cls.IE_DESC, str) and cls.IE_DESC:
            site.setdefault("label", cls.IE_DESC.split(" (", 1)[0][:85])
        for case in cls.get_testcases(include_onlymatching=True):
            url = case.get("url")
            parts = web(url)
            if not parts:
                continue
            site["hosts"].add(parts.hostname.removeprefix("www."))
            site["examples"].setdefault(subtype or "video", url)
    for site in sites.values():
        site["hosts"] = sorted(site["hosts"])
    print(json.dumps({"version": __version__, "extractors": count,
                      "sites": sorted(sites.values(), key=lambda s: s["id"])}))


class QuietLog:
    def __init__(self):
        self.message = None

    def debug(self, _):
        pass

    def warning(self, _):
        pass

    def error(self, message):
        lower = str(message).lower()
        if "drm" in lower:
            self.message = "This video requires DRM playback."
        elif any(word in lower for word in ("sign in", "login", "log in", "cookies", "authentication", "403")):
            self.message = "The site requires sign-in or browser verification. Sign in through Site Browser or import cookies in Templates."
        elif "unsupported url" in lower:
            self.message = "yt-dlp does not recognize this page."
        elif "not available" in lower or "unavailable" in lower:
            self.message = "The site reports that this video is unavailable."


def options(logger, workspace):
    os.environ["DENO_DIR"] = str(workspace / "deno-cache")
    plugin_dirs.value = []
    return {
        "logger": logger,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "cachedir": False,
        "socket_timeout": 20,
        "retries": 1,
        "fragment_retries": 1,
        "extractor_retries": 1,
        "enable_file_urls": False,
        "ffmpeg_location": str(VIDEO_RUNTIME),
        "js_runtimes": {"deno": {"path": str(VIDEO_RUNTIME / "deno")}},
        "remote_components": [],
    }


def cookies_for(ydl, cookies):
    jar = ydl.cookiejar
    jar.set_policy(DefaultCookiePolicy(strict_ns_domain=DefaultCookiePolicy.DomainStrictNonDomain))
    for item in cookies:
        domain = item.get("domain")
        if not domain:
            continue
        expires = item.get("expires")
        jar.set_cookie(Cookie(
            0, item["name"], item["value"], None, False, domain, domain.startswith("."),
            domain.startswith("."), item.get("path") or "/", True, bool(item.get("secure")),
            expires, expires is None, None, None, {}))


def video_url(entry, fallback=None):
    for key in ("webpage_url", "url", "original_url"):
        candidate = entry.get(key)
        if web(candidate):
            return candidate
    if entry.get("ie_key") in {"Youtube", "YoutubeTab"}:
        key = entry.get("id") or entry.get("url")
        if isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_-]{11}", key):
            return "https://www.youtube.com/watch?v=" + key
    return fallback


def emit_entry(entry, seen, title=None, fallback=None, *, flat=False):
    if not isinstance(entry, dict) or entry.get("_type") in {"playlist", "multi_video"}:
        return False
    address = video_url(entry, fallback)
    if not address or address in seen:
        return False
    seen.add(address)
    name = entry.get("title") or entry.get("id")
    name = name[:220] if isinstance(name, str) else None
    if entry.get("is_live") and not flat:
        for fmt in reversed(entry.get("formats") or []):
            manifest = fmt.get("manifest_url") or fmt.get("url")
            if (web(manifest) and str(fmt.get("protocol")).startswith("m3u8") and
                    fmt.get("vcodec") not in (None, "none") and fmt.get("acodec") not in (None, "none")):
                headers = {k: v for k, v in (fmt.get("http_headers") or {}).items()
                           if k.lower() in SAFE_HEADERS and isinstance(v, str)}
                emit("media", url=manifest, filename=name, galleryTitle=title,
                     stream="hls", headers=headers, kind="Videos")
                return True
    formats = entry.get("formats") or []
    audio = entry.get("vcodec") == "none" or (formats and all(fmt.get("vcodec") == "none" for fmt in formats))
    emit("media", url=address, filename=name, galleryTitle=title, videoPage=True,
         kind="Audio" if audio else "Videos")
    return True


def discover(request, logger):
    url = request["url"]
    if not web(url):
        emit("unsupported")
        return
    if not request.get("generic") and not any(cls.suitable(url) for cls in working_extractors()):
        emit("unsupported")
        return
    workspace = request.get("directory")
    context = nullcontext(workspace) if workspace else tempfile.TemporaryDirectory(prefix="MediaHarbor-VideoScan-")
    with context as directory:
        settings = options(logger, Path(directory))
        settings.update({"skip_download": True, "extract_flat": "in_playlist", "playlistend": PLAYLIST_LIMIT})
        with YoutubeDL(settings) as ydl:
            cookies_for(ydl, request.get("cookies", []))
            info = ydl.extract_info(url, download=False)
        if not info:
            emit("error", message=logger.message or "yt-dlp found no downloadable videos on this page.")
            return
        seen = set()
        if "entries" in info:
            title = info.get("title")
            title = title[:500] if isinstance(title, str) else None
            for entry in itertools.islice(info["entries"] or (), PLAYLIST_LIMIT):
                emit_entry(entry, seen, title, flat=True)
        else:
            emit_entry(info, seen, fallback=url)
        emit("done", status=0)


def download(request, logger):
    url = request["url"]
    if not web(url):
        emit("error", message="Enter an HTTP or HTTPS video URL.")
        return
    directory = Path(request["directory"])
    if not directory.is_dir():
        emit("error", message="The temporary download folder is unavailable.")
        return
    progress = {}
    updated = 0.0

    def report(data):
        nonlocal updated
        key = data.get("filename") or ""
        received = data.get("downloaded_bytes")
        total = data.get("total_bytes") or data.get("total_bytes_estimate")
        if not isinstance(received, int):
            return
        progress[key] = (received, total if isinstance(total, int) else 0)
        now = monotonic()
        if now - updated >= 0.25 or data.get("status") == "finished":
            updated = now
            emit("progress", bytes=sum(item[0] for item in progress.values()),
                 total=sum(item[1] for item in progress.values()))

    settings = options(logger, directory)
    settings.update({
        "outtmpl": {"default": str(directory / "video.%(ext)s")},
        "noplaylist": True,
        "playlist_items": "1",
        "format": "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
        "merge_output_format": "mp4/mkv",
        "hls_prefer_native": True,
        "progress_hooks": [report],
        "restrictfilenames": True,
        "updatetime": False,
        "overwrites": False,
    })
    source = web(request.get("source"))
    if source:
        settings["http_headers"] = {"Referer": f"{source.scheme}://{source.netloc}/"}
    with YoutubeDL(settings) as ydl:
        cookies_for(ydl, request.get("cookies", []))
        ydl.extract_info(url, download=True)
    completed = [path for path in directory.iterdir()
                 if path.stem == "video" and path.suffix[1:].lower() in OUTPUT_EXTENSIONS
                 and path.is_file() and not path.is_symlink() and path.stat().st_size > 0]
    if len(completed) == 1:
        emit("saved", filename=completed[0].name)
    else:
        emit("error", message=logger.message or "yt-dlp did not produce a complete media file.")


def main():
    if sys.argv[1:] == ["catalog"]:
        catalog()
        return
    try:
        os.setpgid(0, 0)
    except PermissionError:
        pass
    logger = QuietLog()
    try:
        request = json.loads(sys.stdin.readline(8 * 1024 * 1024))
        if request["command"] == "scan":
            discover(request, logger)
        elif request["command"] == "download":
            download(request, logger)
        else:
            emit("error", message="Unknown yt-dlp request.")
    except DownloadError:
        emit("error", message=logger.message or "yt-dlp could not retrieve this video.")
    except Exception:
        emit("error", message=logger.message or "yt-dlp could not finish the request.")


if __name__ == "__main__":
    main()
