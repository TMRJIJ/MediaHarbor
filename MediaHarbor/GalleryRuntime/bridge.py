"""Private JSON-lines interface between Media Harbor and gallery-dl."""

from http.cookiejar import Cookie
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import logging
from pathlib import Path
import select
import sys
from time import monotonic
from urllib.parse import parse_qs, urlencode, urlsplit

# The interpreter runs in isolated mode. Only the bundled packages are added.
sys.path.insert(0, str(Path(sys.executable).resolve().parents[1] /
                       "lib" / "python3.13" / "site-packages"))

from gallery_dl import config, exception, extractor, job, output, version
from gallery_dl.extractor.common import Extractor
from gallery_dl.extractor.oauth import OAuthBase
from requests import Request
from requests.cookies import get_cookie_header

EXCLUDED = {"directlink", "generic", "noop", "oauth", "recursive", "test", "ytdl"}
SAFE_HEADERS = {"accept", "accept-language", "authorization", "origin", "referer", "user-agent"}
OAUTH_KEYS = {"access-token", "access-token-secret", "refresh-token",
              "api-key", "api-secret", "client-id", "client-secret"}
ITEM_LIMIT = 5000
CHILD_LIMIT = 100
IMAGE_HOST_CATEGORIES = {"imagebam", "imgbb", "imgbox"}
IMAGE_HOST_ALIASES = {
    "imxto": ("img.yt",),
    "imxtw": ("imx.tw",),
    "imgdrive": ("imgdrive.com", "imgtaxi.com", "imgtaxi.net", "imgwallet.com", "imgwallet.net"),
    "imagetwist": ("imagehaha.com",),
    "pixhost": ("pixhost.cc", "pixhost.to", "pixhost.org"),
    "postimg": ("postimg.org", "postimages.cc", "postimages.org", "pixxxels.cc", "pixxxels.org"),
    "silverpic": ("silverpic.com",),
}


def emit(event, **data):
    print(json.dumps({"event": event, **data}, ensure_ascii=True, separators=(",", ":")), flush=True)


def read_request():
    line = sys.stdin.readline(8 * 1024 * 1024)
    if not line:
        raise EOFError()
    return json.loads(line)


def is_web(url):
    if not isinstance(url, str):
        return False
    parts = urlsplit(url)
    return parts.scheme in {"http", "https"} and bool(parts.hostname) and parts.username is None


def catalog():
    sites = {}
    oauth = set()
    for cls in extractor.extractors():
        category = cls.category or cls.basecategory
        if category == "oauth":
            oauth.add(cls.subcategory)
            continue
        if not category or category in EXCLUDED:
            continue
        example = getattr(cls, "example", "")
        if not example or not is_web(example):
            continue
        site = sites.setdefault(category, {"id": category, "examples": {}, "hosts": set()})
        site["examples"].setdefault(cls.subcategory, example)
        site["hosts"].add(urlsplit(example).hostname.removeprefix("www."))
        if cls.subcategory == "image" and is_image_host(cls):
            site["linkedImages"] = True
            site["hosts"].update(IMAGE_HOST_ALIASES.get(category, ()))
        for _, instance, _ in getattr(cls, "instances", ()):
            if instance and is_web(instance):
                site["hosts"].add(urlsplit(instance).hostname)
    for category, site in sites.items():
        site["oauth"] = category in oauth
        site["hosts"] = sorted(site["hosts"])
    print(json.dumps({"version": version.__version__, "sites": sorted(sites.values(), key=lambda s: s["id"])}))


def is_image_host(ext):
    return ext.basecategory == "imagehost" or ext.category in IMAGE_HOST_CATEGORIES


def install_cookies(cookies, category):
    original = Extractor._init_cookies

    def initialize(instance):
        original(instance)
        for item in cookies:
            domain = item["domain"]
            if category == "twitter" and domain == "x.com" and item["name"] in {"auth_token", "ct0", "twid"}:
                domain = ".x.com"  # X's extractor looks up these cookies using this exact domain.
            path = item.get("path") or "/"
            expires = item.get("expires")
            instance.cookies.set_cookie(Cookie(
                0, item["name"], item["value"], None, False, domain,
                domain.startswith("."), domain.startswith("."), path, True,
                item.get("secure", False), expires, expires is None, None, None, {}))

    Extractor._init_cookies = initialize


def watch_refreshes(provider, options):
    endpoints = {
        "deviantart": "https://www.deviantart.com/oauth2/token",
        "pixiv": "https://oauth.secure.pixiv.net/auth/token",
        "reddit": "https://www.reddit.com/api/v1/access_token",
    }
    endpoint = endpoints.get(provider)
    current = options.get("refresh-token")
    if not endpoint or not current:
        return
    original = Extractor.request

    def request(instance, url, *args, **kwargs):
        nonlocal current
        response = original(instance, url, *args, **kwargs)
        data = kwargs.get("data")
        if (url == endpoint and isinstance(data, dict) and data.get("grant_type") == "refresh_token"
                and data.get("refresh_token") == current and response.ok):
            payload = response.json()
            values = payload.get("response", payload) if isinstance(payload, dict) else None
            token = values.get("refresh_token") if isinstance(values, dict) else None
            if isinstance(token, str) and token and token != current:
                current = token
                emit("refreshed", options={"refresh-token": token})
        return response

    Extractor.request = request


def gallery_title(metadata, include_title=False):
    for key in ("gallery", "album", "collection"):
        value = metadata.get(key)
        if isinstance(value, dict):
            value = value.get("title") or value.get("name")
        if isinstance(value, str) and value.strip():
            return value.strip()[:500]
    keys = ("gallery_title", "album_title", "collection_title", "gallery_name", "album_name")
    if include_title:
        keys += ("title",)
    for key in keys:
        value = metadata.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:500]
    return None


class MediaJob(job.Job):
    def __init__(self, ext, parent=None, source=None):
        super().__init__(ext, parent)
        self.depth = 0 if parent is None else parent.depth + 1
        self.root = self if parent is None else parent.root
        self.parent_title = parent.gallery_title if parent is not None else None
        self.gallery_title = self.parent_title
        if parent is None:
            self.source = source
            self.seen = set()
            self.children = {ext.url}
            self.skipped = 0

    def handle_directory(self, metadata):
        self.gallery_title = gallery_title(metadata, include_title=True) or self.parent_title

    def handle_url(self, url, metadata):
        root = self.root
        if len(root.seen) >= ITEM_LIMIT:
            raise exception.StopExtraction(self.depth + 1)
        candidate = url.removeprefix("ytdl:") if isinstance(url, str) else url
        stream = None
        if is_web(candidate):
            path = urlsplit(candidate).path.lower()
            stream = "hls" if path.endswith(".m3u8") else "dash" if path.endswith(".mpd") else None
        video_page = isinstance(url, str) and url.startswith("ytdl:") and bool(is_web(candidate)) and not stream
        if stream or video_page:
            url = candidate
        if not is_web(url) or metadata.get("_http_method", "GET") != "GET":
            root.skipped += 1
            return
        if url in root.seen:
            return
        root.seen.add(url)

        session = self.extractor.session
        headers = {key: value for key, value in session.headers.items()
                   if key.lower() in SAFE_HEADERS and key.lower() != "authorization" and isinstance(value, str)}
        source_host = urlsplit(self.extractor.url).hostname
        target_host = urlsplit(url).hostname
        if headers.get("Referer") and urlsplit(headers["Referer"]).hostname != source_host:
            headers.pop("Referer")
        if source_host != target_host and "Referer" not in headers:
            source = urlsplit(self.extractor.url)
            headers["Referer"] = f"{source.scheme}://{source.netloc}/"
        for key, value in (metadata.get("_http_headers") or {}).items():
            if key.lower() in SAFE_HEADERS and isinstance(value, str):
                headers[key] = value
        cookie_header = get_cookie_header(session.cookies, Request("GET", url).prepare())
        if cookie_header:
            headers["Cookie"] = cookie_header
        extension = metadata.get("extension")
        filename = metadata.get("filename")
        if root.source is not None and not extension:
            filename = None
        stream_cookies = []
        if stream:
            for cookie in session.cookies:
                domain = cookie.domain.lower()
                base = domain.lstrip(".")
                if base and (target_host == base or (domain.startswith(".") and target_host.endswith("." + base))):
                    stream_cookies.append({
                        "name": cookie.name, "value": cookie.value, "domain": domain,
                        "path": cookie.path or "/", "secure": cookie.secure, "expires": cookie.expires,
                    })
        emit("media", url=url, source=root.source, headers=headers, stream=stream, videoPage=bool(video_page),
             streamCookies=stream_cookies, galleryTitle=gallery_title(metadata) or self.gallery_title,
             extension=extension if isinstance(extension, str) else None,
             filename=filename if isinstance(filename, str) else None)

    def handle_queue(self, url, metadata):
        root = self.root
        if len(root.seen) >= ITEM_LIMIT:
            raise exception.StopExtraction(self.depth + 1)
        if self.depth >= 3 or len(root.children) >= CHILD_LIMIT or url in root.children or not is_web(url):
            return
        cls = metadata.get("_extractor")
        child = cls.from_url(url) if cls else extractor.find(url)
        if child and child.category not in EXCLUDED:
            root.children.add(url)
            self.status |= MediaJob(child, self).run()


def scan(request):
    url = request["url"]
    if request.get("mastodon") and is_web(url):
        parts = urlsplit(url)
        config.set(("extractor", "mastodon"), parts.hostname, {"root": parts.scheme + "://" + parts.netloc})
    linked = request.get("linkedImages")
    if linked is None:
        ext = extractor.find(url) if is_web(url) else None
        targets = [(ext, None)] if ext and ext.category not in EXCLUDED else []
    else:
        host = urlsplit(url).hostname
        targets = []
        for address in dict.fromkeys(linked[:100]):
            if is_web(address) and urlsplit(address).hostname == host:
                ext = extractor.find(address)
                if ext and ext.subcategory == "image" and is_image_host(ext):
                    targets.append((ext, address))
    if not targets:
        emit("unsupported")
        return

    ext = targets[0][0]
    provider = "mastodon" if ext.basecategory == "mastodon" else ext.category
    emit("match", category=provider, cookieDomain=ext.cookies_domain or "")
    credentials = read_request()
    install_cookies(credentials.get("cookies", []), ext.category)
    options = credentials.get("options", {})
    watch_refreshes(provider, options)
    for key, value in options.items():
        if key in OAUTH_KEYS:
            config.set(("extractor", ext.category), key, value)
    config.set(("extractor",), "timeout", 20 if linked is None else 8)
    config.set(("extractor",), "retries", 1 if linked is None else 0)
    config.set(("extractor",), "cache", False)
    config.set(("cache",), "file", ":memory:")
    status = skipped = 0
    for target, source in targets:
        if target.category == ext.category:
            media_job = MediaJob(target, source=source)
            status |= media_job.run()
            skipped += media_job.skipped
    emit("done", status=status, skipped=skipped)


def callback_values(raw):
    query = raw.strip()
    if "?" in query:
        query = query.split("?", 1)[1]
    return {key: values[0] for key, values in parse_qs(query.split("#", 1)[0]).items()}


def authorize(request):
    provider = request["provider"]
    options = request.get("options", {})
    for key, value in options.items():
        if key in OAUTH_KEYS:
            config.set(("extractor", provider), key, value)
    config.set(("extractor", "oauth"), "cache", False)
    config.set(("extractor",), "timeout", 25)
    config.set(("extractor",), "retries", 0)
    config.set(("cache",), "file", ":memory:")
    name = "oauth:" + provider
    if provider == "mastodon":
        name += ":" + request["instance"]
    auth = extractor.find(name)
    if not auth or not isinstance(auth, OAuthBase):
        emit("error", message="This provider does not offer gallery-dl OAuth.")
        return

    captured = {}

    def credentials(keys, values):
        captured.update(zip(keys, values))
        return "\nAuthorization completed. Return to Media Harbor.\n"

    def open_authorization(url, params, recv=None):
        address = url + "?" + urlencode(params)
        if recv is not None:  # Pixiv provides its code in a native-app redirect.
            emit("authorize", url=address, manual=True)
            raw = sys.stdin.readline(8192).strip()
            return callback_values(raw).get("code", raw)

        def accepts(values):
            if params.get("state"):
                return values.get("state") == params["state"] and ("code" in values or "error" in values)
            return values.get("oauth_token") == params.get("oauth_token") and bool(values.get("oauth_verifier"))

        class Callback(BaseHTTPRequestHandler):
            def setup(self):
                self.request.settimeout(2)
                super().setup()

            def do_GET(self):
                values = callback_values(self.path) if self.path.startswith("/?") else {}
                if accepts(values):
                    self.server.callback = values
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(b"Authorization received. Return to Media Harbor.")
                else:
                    self.send_error(400, "Invalid authorization response")

            def log_message(self, *_):
                pass

        with HTTPServer(("127.0.0.1", 6414), Callback) as server:
            server.callback = None
            emit("authorize", url=address, manual=False)
            deadline = monotonic() + 300
            while (remaining := deadline - monotonic()) > 0:
                ready, _, _ = select.select([server, sys.stdin], [], [], remaining)
                if server in ready:
                    server.handle_request()
                    if server.callback is not None:
                        return server.callback
                if sys.stdin in ready:
                    raw = sys.stdin.readline(8192)
                    if not raw:
                        break
                    values = callback_values(raw)
                    if accepts(values):
                        return values
                    emit("inputError", message="Paste the complete callback URL from this authorization attempt.")
            raise TimeoutError()

    auth._generate_message = credentials
    auth.open = open_authorization
    auth.send = lambda *_: None
    # Upstream may print status and credentials. Our protocol uses structured events only.
    from gallery_dl.extractor import oauth as oauth_module
    oauth_module.stdout_write = lambda *_: None
    auth.initialize()
    list(auth.items() or ())
    if captured:
        emit("connected", options={**options, **captured})
    else:
        emit("error", message="The provider did not grant access. Try authorizing again.")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "catalog":
        catalog()
        return
    output.initialize_logging(logging.CRITICAL)
    try:
        request = read_request()
        if request["command"] == "scan":
            scan(request)
        elif request["command"] == "oauth":
            authorize(request)
        else:
            emit("error", message="Unknown gallery-dl request.")
    except OSError as error:
        if getattr(error, "errno", None) == 48:
            emit("error", message="The OAuth callback port is in use. Close other authorization windows and try again.")
        else:
            emit("error", message="gallery-dl could not finish the request.")
    except Exception:
        emit("error", message="gallery-dl could not finish the request.")


if __name__ == "__main__":
    main()
