import Foundation

enum YTDLPIntegration {
    static let catalog: GalleryCatalog? = GalleryProcess.runtime
        .flatMap { try? Data(contentsOf: $0.appending(path: "video-sites.json")) }
        .flatMap { try? JSONDecoder().decode(GalleryCatalog.self, from: $0) }

    static func cookieHosts(for url: URL) -> Set<String> {
        guard let host = url.host?.lowercased() else { return [] }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return [host, "youtube.com", "www.youtube.com"]
        }
        if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") {
            return [host, "x.com", "twitter.com"]
        }
        return [host]
    }

    @MainActor
    static func scan(_ url: URL, cookies: [StreamCookie], allowGeneric: Bool,
                     onMedia: (MediaCandidate, [String: String]) -> Void) async throws -> GalleryScanOutcome {
        struct Request: Encodable {
            let command = "scan"
            let url: URL
            let cookies: [StreamCookie]
            let generic: Bool
            let directory: String
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaHarbor-VideoScan-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try GalleryProcess(script: "video_bridge.py", isolatedGroup: true)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled { process.stop() }
        }
        defer {
            timeout.cancel()
            process.stop()
        }
        try process.send(Request(url: url, cookies: cookies, generic: allowGeneric, directory: directory.path))
        var outcome = GalleryScanOutcome()
        for try await event in process.events {
            try Task.checkCancellation()
            switch event.event {
            case "media":
                guard let address = event.url.flatMap({ URL.web($0.absoluteString) }) else { continue }
                let candidate = MediaCandidate(url: address, source: url, kind: event.kind ?? .video,
                                               suggestedFilename: event.filename, stream: event.stream,
                                               galleryTitle: event.galleryTitle, videoPage: event.videoPage)
                onMedia(candidate, event.headers ?? [:])
                outcome.count += 1
            case "done", "unsupported":
                return outcome
            case "error":
                outcome.note = event.message
                return outcome
            default:
                continue
            }
        }
        try Task.checkCancellation()
        return outcome
    }
}

struct ExtractedVideoResult {
    let directory: URL
    var output: URL?
    var error: String?
}

@MainActor
final class ExtractedVideoDownload {
    private let process: GalleryProcess
    private var task: Task<Void, Never>?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0

    init(media: MediaCandidate, cookies: [StreamCookie], completion: @escaping (ExtractedVideoResult) -> Void) throws {
        struct Request: Encodable {
            let command = "download"
            let url: URL
            let source: URL?
            let cookies: [StreamCookie]
            let directory: String
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaHarbor-Video-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let process: GalleryProcess
        do {
            process = try GalleryProcess(script: "video_bridge.py", isolatedGroup: true)
            do {
                try process.send(Request(url: media.url, source: media.source, cookies: cookies, directory: directory.path))
            } catch {
                process.stop()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.process = process
        task = Task { [weak self] in
            var result = ExtractedVideoResult(directory: directory, error: "yt-dlp stopped before it could save the video.")
            defer {
                process.stop()
                completion(result)
            }
            do {
                for try await event in process.events {
                    try Task.checkCancellation()
                    switch event.event {
                    case "progress":
                        self?.received = max(0, event.bytes ?? 0)
                        self?.expected = max(0, event.total ?? 0)
                    case "saved":
                        if let name = event.filename,
                           name.range(of: #"^video\.[a-zA-Z0-9]{1,12}$"#, options: .regularExpression) != nil {
                            let output = directory.appending(path: name)
                            if let values = try? output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                               values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 {
                                result.output = output
                                result.error = nil
                            }
                        }
                        return
                    case "error":
                        result.error = event.message ?? result.error
                        return
                    default:
                        continue
                    }
                }
            } catch {
                if !Task.isCancelled { result.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        task?.cancel()
        process.stop()
    }
}
