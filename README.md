# Media Harbor

Media Harbor is a native bulk media downloader for macOS Tahoe 26 and newer on Apple Silicon and Intel. It finds images, video, audio, and other files on websites, in forum threads, and in URL lists. The built app includes its download engines and runtimes.

## Install and get help

Unzip the app archive if you have one, move **Media Harbor.app** to Applications, and open it. To run from source, follow [Build from source](#build-from-source).

Open **Help → Media Harbor Help** for instructions in the app. The **Support** section in the sidebar also opens Help and About. Hover over a control for a short description.

## Getting started

1. Open **Media Harbor**, then choose **New Download** or press **⌘N**.
2. Choose a source.
   - **Website** opens the page in the built-in browser and scans for files. Review the results, select the file types you want, and click **Queue**. Enable automatic queueing to download the first scan's results immediately.
   - **URL List** accepts one HTTP or HTTPS link per line. Paste a list or import a UTF-8 text file.
   - **Image Search** opens Bing, Google, Yandex, DuckDuckGo, or Yahoo Images. On Google, open an image result and use **Scan Page** to collect the image exposed in the preview.
3. In **Downloads**, use the toolbar to pause the queue or the row controls to pause and resume a single file. **Clear Queue** cancels active downloads and clears the list while keeping saved files and gallery images.
4. In **Gallery**, click a thumbnail to preview it or choose **Slideshow** to advance through the images every three seconds.

Files save to **Downloads/Media Harbor** by default. Failed downloads can be retried from the queue. When a server supplies resumable transfers, pausing saves the partial download for later. Otherwise the next attempt starts at the beginning.

Settings (**⌘,**) lets you choose a download folder, simultaneous downloads, retry count, and whether queued files start automatically. When automatic start is off, choose **Start Queue** to start the current batch or use the play button on an individual row. Files you add later wait for another start.

Under **Settings → Downloads → Create folders by**, choose **URL**, **Gallery title**, or **Page title**. URL folders use the source website’s host and path. Direct links without a source page are grouped by host. The title options fall back to URL naming when the relevant title is unavailable. The setting applies when files enter the queue.

## Video streams

Paste an HLS (`.m3u8`) or MPEG-DASH (`.mpd`) playlist into **URL List**, or scan a page that exposes the stream. FFmpeg saves compatible audio and video tracks together in an MP4. For a live stream, use **Stop & Save** on the queue row to keep what has been recorded. Pausing a stream stops the recording, and resuming starts a new one.

For a protected stream, sign in through **Site Browser** or import matching cookies under **Templates → Authentication**. Stream requests use the applicable cookies. Some video pages expose the playlist only after playback starts. Play the video in Site Browser, then scan again.

## yt-dlp videos and playlists

Open a video or playlist with **New Download → Website**, or browse **Templates → yt-dlp Sites** for more than 1,200 site templates. On sites handled by both extractors, the regular scan starts with gallery-dl. Choose **Find Videos with yt-dlp** in Site Browser’s scan settings to use yt-dlp for the current page, including embedded videos it can recognize.

Review the videos or audio tracks before queueing them. A playlist can expose up to 250 entries in one scan. **Gallery title** folder naming uses the playlist title. yt-dlp resolves media links when the job starts and uses the bundled FFmpeg to merge separate audio and video tracks. Restarting a paused yt-dlp job begins a new transfer.

yt-dlp uses matching Site Browser or imported cookies. Some sites require a fresh login or browser verification, and their availability can change. YouTube’s EJS scripts and Deno are bundled.

## Websites, forums, and sign-in

Sign in through **Site Browser**, then navigate to the protected page and select **Scan Page**. The download engine uses matching cookies from that browser. HTTP Basic and Digest credentials are requested by the browser and used for the current app session.

For X, start with a post URL or a profile’s **Media** tab. If X redirects to sign-in, Media Harbor returns to the starting page and scans it after login.

The scanner follows same-origin next-page links up to the page limit. Increase the limit under the scan settings for longer threads, or enable **Follow links on the same website** to explore beyond pagination. **Auto-scroll during scans** is enabled by default and collects files as more results load, up to 20 scroll steps per page. Expand collapsed content before scanning if needed. Use **Home** to return to the starting URL. Discovered files accumulate while browsing until you start a new website collection or image search.

For off-site galleries, enable **Follow links to known gallery domains** in Site Browser’s scan settings. Both text links and linked thumbnails qualify when the destination domain matches a Web Rule or gallery-dl site. A forum’s optional **Linked gallery selector** enables handoff for that forum and narrows which links are checked. For example, `article a[href]:has(img)` matches thumbnails in forum posts. Direct image links go straight to the results.

Media Harbor can verify full-size files directly when an IMX, Imgbox, or Pixhost thumbnail matches its destination. It also looks up up to 100 linked image pages with gallery-dl, including ImageBam, ImageVenue, ImageTwist, Postimages, ImgBB, and TurboImageHost. The scan recognizes alternate domains such as `pixhost.to` and `postimages.org`. When a lookup yields a full-size image, it replaces the thumbnail. Otherwise the preview remains eligible. The browser can also follow up to 25 linked galleries or other destinations, with up to 10 next pages per destination.

**Ignore page assets** is on by default in Site Browser’s scan settings. It filters common logos, avatars, icons, emoji, and loading images using page labels and filenames. Ordinary GIFs and small images remain eligible. Turn it off and start a new scan if a desired image was filtered.

## gallery-dl templates and authentication

Open **Templates → gallery-dl Sites** to browse 298 site templates with example URL formats. On supported pages, Media Harbor runs gallery-dl first and shows its discovered files in the regular review panel. The browser scanner handles other pages and can help when gallery-dl finds nothing. Use **Web Rules** to edit the built-in browser rules or create a CSS template that takes priority over gallery-dl. For example, `article img, article a[download]` finds images and attachment links inside article elements.

Open **Templates → Authentication** to manage access.

- **Cookies.** Sign in through Site Browser or import a Netscape-format `cookies.txt` file. The app passes relevant cookies to gallery-dl. Imported cookies are kept for the current app session. For X, sign in before scanning a post or profile’s Media tab, or import cookies and choose **Scan Page** if X shows its login screen.
- **OAuth.** Choose DeviantArt, Flickr, Mastodon, Pixiv, Reddit, SmugMug, or Tumblr and follow the provider’s consent screen. Flickr requires your API key and secret. Mastodon requires an instance hostname. Pixiv requires the authorization code from the final callback. OAuth credentials are saved in macOS Keychain, and you can remove them with **Disconnect**.

For files that require an authenticated request, the app keeps private request headers in memory. If an authenticated link expires or the app has restarted, rescan the source to refresh its session.

## Scope

The app queues direct HTTP and HTTPS files, HLS and DASH playlists, and recognized yt-dlp media pages. DRM-protected media and general codec conversion are outside this build’s scope. Browser scans are capped at 50 pages and 5,000 discovered URLs. gallery-dl discovery is capped at 5,000 files, 100 nested sources, and 90 seconds per scan.

## How it’s built

SwiftUI and Liquid Glass power the interface. WebKit provides the browser and website sign-in, a bundled JavaScript scanner finds media in web pages, and Foundation manages direct downloads. OAuth credentials are stored in macOS Keychain. The image viewer uses ImageIO to make thumbnails from saved files.

| Bundled component | Version | Role |
| --- | --- | --- |
| [gallery-dl](https://github.com/mikf/gallery-dl) | 1.32.19 | Discovers media and galleries on supported sites |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 2026.10.26 | Discovers and downloads video, audio, and playlists |
| [FFmpeg](https://ffmpeg.org/) | 9.0.2 | Records HLS and DASH streams and combines audio and video tracks |
| [CPython](https://www.python.org/) | 3.13.18 | Runs gallery-dl, yt-dlp, and the app’s Python bridges |
| [Deno](https://deno.com/) and [yt-dlp EJS](https://github.com/yt-dlp/ejs) | 2.9.8 and 0.8.0 | Run YouTube’s JavaScript support |

The complete list of Python wheels and runtime checksums is in the [gallery lockfile](Scripts/gallery-runtime.lock.json) and [video lockfile](Scripts/video-runtime.lock.json). Third-party licenses ship with the app. The [FFmpeg source, cookie patch, and build script](MediaHarbor/VideoRuntime/Source) are included alongside its [LGPL notice](MediaHarbor/VideoRuntime/COPYING.LGPLv2.1).

## Build from source

Use a Mac running macOS Tahoe 26 or later, Xcode with the macOS 26 SDK or later, and Python 3.13. From the repository root, prepare the bundled runtimes. The first command downloads pinned dependencies and verifies their checksums. The second builds FFmpeg for both Mac architectures.

```sh
python3 Scripts/prepare_gallery_runtime.py
sh MediaHarbor/VideoRuntime/Source/build-ffmpeg.sh
```

Open `MediaHarbor.xcodeproj` in Xcode with the macOS 26 SDK or newer, select **MediaHarbor**, and run it on **My Mac**. For a universal build from the command line:

```sh
xcodebuild -project MediaHarbor.xcodeproj -scheme MediaHarbor \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/MediaHarborBuild CODE_SIGN_IDENTITY=- build
```

The resulting app is at `/tmp/MediaHarborBuild/Build/Products/Release/Media Harbor.app`. The local signature is for running the app on this Mac.

## Contributing

Bug reports, site-rule improvements, documentation fixes, and code contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for what to include in an issue or pull request and how to verify a change locally.
