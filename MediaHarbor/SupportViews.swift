import AppKit
import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Media Harbor Help", detail: "Find files, manage downloads, and browse your saved images.")

                topic("Start a download", icon: "plus.circle") {
                    Text("Choose New Download (⌘N), then pick Website, URL List, or Image Search.")
                    Text("For a website or image search, scan the page, review the discovered files, and click Queue. URL List accepts one HTTP or HTTPS link per line or a UTF-8 text file.")
                }
                topic("Scan websites and forums", icon: "globe") {
                    Text("Sign in through Site Browser if needed, open the page with the media, then click Scan Page. Enable auto-scroll for content that loads as you scroll. Increase Pages to scan for long threads.")
                    Text("ViperGirls scans follow supported image links in posts automatically. For other sites, turn on Follow links to known gallery domains in Scan settings. If a file is missing, try turning off Ignore page assets and scanning again.")
                }
                topic("Use templates and sign in", icon: "key") {
                    Text("Browse gallery-dl Sites and yt-dlp Sites in Templates for supported sites and example URLs. Create a Web Rule to specify which parts of a page contain media or links to galleries.")
                    Text("Under Templates → Authentication, import a cookies.txt file for this session or connect an account with OAuth where supported.")
                }
                topic("Download videos and streams", icon: "film") {
                    Text("In Scan settings, choose Find Videos with yt-dlp for supported video pages and playlists. If the player loads a stream after playback starts, play it before scanning again.")
                    Text("Paste an HLS (.m3u8) or DASH (.mpd) playlist into URL List to download it with FFmpeg. Use Stop & Save to keep a live recording. Resuming a paused live stream starts a new recording.")
                }
                topic("Manage the queue and saved files", icon: "arrow.down.circle") {
                    Text("In Downloads, expand a project to see its files. Use the globe to reopen the source in Site Browser, or use Retry Project to retry unfinished files. Select Preview beside a saved file to open it in Quick Look.")
                    Text("Clear Queue cancels active transfers and keeps files you already saved.")
                    Text("Open Settings (⌘,) to set the save folder, folder naming, simultaneous downloads, retries, and automatic start. If automatic start is off, click Start Queue or start individual files.")
                }
                topic("View downloaded images", icon: "photo.on.rectangle.angled") {
                    Text("Open Gallery and select a thumbnail to preview it. Use the arrow keys to browse, or choose Slideshow to advance automatically.")
                }
                topic("Update the app and dependencies", icon: "arrow.trianglehead.clockwise") {
                    Text("In Settings, Check for Updates finds signed releases, including their bundled dependencies. You can also opt in to installation at launch when the app is idle.")
                }
            }
            .padding(26)
        }
        .frame(minWidth: 500, minHeight: 420)
    }

    private func topic<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AboutView: View {
    let galleryVersion: String

    private var version: String {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(release) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    PageHeading(title: "Media Harbor", detail: version)
                }
                Text("A bulk media downloader for macOS Tahoe 26 or later, built for Apple Silicon and Intel.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("How it’s built").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("SwiftUI and Liquid Glass power the interface. WebKit handles browsing and sign-in, Foundation manages file transfers, and macOS Keychain stores OAuth credentials.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Bundled dependencies").font(.headline).accessibilityAddTraits(.isHeader)
                    dependency("gallery-dl", version: galleryVersion, detail: "Discovers images and other files on supported sites.")
                    dependency("yt-dlp", version: YTDLPIntegration.catalog?.version, detail: "Finds and downloads videos, audio, and playlists.")
                    dependency("FFmpeg", detail: "Records streams and combines separate audio and video.")
                    dependency("Python and Deno", detail: "Run the extractors and YouTube’s JavaScript support.")
                    Text("Third-party license files ship with the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
        }
        .frame(minWidth: 450, minHeight: 400)
    }

    private func dependency(_ name: String, version: String? = nil, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text([name, version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
                .fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
