import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

private struct TransferResult: Sendable {
    var output: URL?
    var error: String?
    var resumeData: Data?
    var retryable = false
    var stream: StreamFormat?
}

private final class DownloadRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        if response.url?.scheme != request.url?.scheme || response.url?.host != request.url?.host ||
            response.url?.port != request.url?.port {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(request)
    }
}

@MainActor @Observable
final class Transfers {
    @MainActor
    private enum RunningVideo {
        case stream(VideoProcess)
        case extracted(ExtractedVideoDownload)

        var progress: (Int64, Int64) {
            switch self {
            case .stream(let stream): (stream.bytesWritten, 0)
            case .extracted(let download): (download.received, download.expected)
            }
        }

        func cancel() {
            switch self {
            case .stream(let stream): stream.cancel()
            case .extracted(let download): download.cancel()
            }
        }
    }

    private struct PauseRequest {
        var data: Data?
        var receivedResumeData = false
        var finished = false
    }

    private(set) var items: [Transfer] = []
    private var archivedImages: [Transfer] = []
    private(set) var isPaused = false
    private(set) var storageError: String?
    private let stateFile: URL
    private let preferences: UserDefaults
    private let session: URLSession
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var videoTasks: [UUID: RunningVideo] = [:]
    private var stoppedVideos: Set<UUID> = []
    private(set) var finalizingVideos: Set<UUID> = []
    private var pausing: [UUID: PauseRequest] = [:]
    private var approved: Set<UUID> = []
    private var privateHeaders: [URL: [String: String]] = [:]
    private var privateStreamCookies: [URL: [StreamCookie]] = [:]
    private var timer: Timer?
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    var connections: Int {
        didSet {
            preferences.set(connections, forKey: "connections")
            schedule()
        }
    }
    var retries: Int { didSet { preferences.set(retries, forKey: "retries") } }
    var folder: URL { didSet { preferences.set(folder.path, forKey: "destination") } }
    var folderRule: DownloadFolderRule {
        didSet { preferences.set(folderRule.rawValue, forKey: "downloadFolderRule") }
    }
    var autoStart: Bool {
        didSet {
            preferences.set(autoStart, forKey: "autoStartDownloads")
            if !autoStart {
                approved.formUnion(tasks.keys)
                approved.formUnion(videoTasks.keys)
            }
            schedule()
        }
    }

    init(stateFile: URL? = nil, preferences: UserDefaults = .standard) {
        let support = URL.applicationSupportDirectory.appending(path: "MediaHarbor", directoryHint: .isDirectory)
        self.stateFile = stateFile ?? support.appending(path: "queue.json")
        self.preferences = preferences
        folder = preferences.string(forKey: "destination").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.downloadsDirectory.appending(path: "Media Harbor", directoryHint: .isDirectory)
        folderRule = preferences.string(forKey: "downloadFolderRule").flatMap(DownloadFolderRule.init(rawValue:)) ?? .none
        connections = min(12, max(1, preferences.object(forKey: "connections") as? Int ?? 4))
        retries = min(8, max(0, preferences.object(forKey: "retries") as? Int ?? 3))
        autoStart = preferences.object(forKey: "autoStartDownloads") as? Bool ?? true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 12
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config, delegate: DownloadRedirects(), delegateQueue: nil)
        do {
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: self.stateFile))
            isPaused = state.paused
            archivedImages = state.archivedImages ?? []
            items = state.items.map { item in
                var item = item
                if item.status == .downloading { item.status = state.paused ? .paused : .queued }
                return item
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A new installation starts with an empty queue.
        } catch {
            storageError = "The saved queue could not be read. " + error.localizedDescription
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func importCookies(_ cookies: [HTTPCookie], for urls: [URL]) {
        let hosts = Set(urls.compactMap(\.host))
        for cookie in cookies {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if hosts.contains(where: { $0 == domain || $0.hasSuffix("." + domain) }) {
                session.configuration.httpCookieStorage?.setCookie(cookie)
            }
        }
    }

    func setCredential(_ credential: URLCredential, for space: URLProtectionSpace) {
        session.configuration.urlCredentialStorage?.setDefaultCredential(credential, for: space)
    }

    @discardableResult
    func enqueue(_ media: [MediaCandidate], privateHeaders headers: [URL: [String: String]] = [:],
                 streamCookies: [URL: [StreamCookie]] = [:]) -> Int {
        privateHeaders.merge(headers) { _, new in new }
        privateStreamCookies.merge(streamCookies) { _, new in new }
        var seen = Set(items.map(\.media.url))
        let new = media.filter { seen.insert($0.url).inserted }
        items.append(contentsOf: new.map {
            Transfer(media: $0, folder: folderRule.destination(base: folder, media: $0),
                     status: isPaused ? .paused : .queued)
        })
        save()
        schedule()
        return new.count
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            for index in items.indices where [.queued, .retrying].contains(items[index].status) {
                items[index].status = .paused
            }
            for id in Array(tasks.keys) { pause(id, manually: false) }
            for id in Array(videoTasks.keys) { pause(id, manually: false) }
        } else {
            for index in items.indices where items[index].status == .paused && items[index].manuallyPaused != true {
                items[index].status = .queued
            }
            if !autoStart { startQueue() }
        }
        save()
        schedule()
    }

    var hasUnapprovedDownloads: Bool {
        !isPaused && items.contains(where: needsStart)
    }

    func needsStart(_ item: Transfer) -> Bool {
        !autoStart && [.queued, .retrying].contains(item.status) && !approved.contains(item.id)
    }

    var galleryImages: [Transfer] {
        archivedImages + items.filter { $0.status == .complete && $0.kind == .image && $0.output != nil }
    }

    func startQueue() {
        approved.formUnion(items.lazy.filter { [.queued, .retrying].contains($0.status) }.map(\.id))
        schedule()
    }

    func pause(_ id: UUID, manually: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !finalizingVideos.contains(id),
              [.downloading, .queued, .retrying].contains(items[index].status) else { return }
        items[index].status = .paused
        items[index].manuallyPaused = manually
        if let stream = videoTasks[id] {
            stoppedVideos.insert(id)
            stream.cancel()
        }
        if let task = tasks[id] {
            pausing[id] = PauseRequest()
            task.cancel { [weak self] data in
                Task { @MainActor in
                    guard let self, self.pausing[id] != nil else { return }
                    self.pausing[id]?.data = data
                    self.pausing[id]?.receivedResumeData = true
                    self.finishPause(id)
                }
            }
        }
        save()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              [.queued, .failed, .paused, .retrying].contains(items[index].status) else { return }
        if !autoStart { approved.insert(id) }
        items[index].status = isPaused ? .paused : .queued
        items[index].manuallyPaused = false
        items[index].attempts = 0
        items[index].error = nil
        items[index].retryDate = nil
        save()
        schedule()
    }

    func remove(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            privateHeaders[item.media.url] = nil
            privateStreamCookies[item.media.url] = nil
        }
        tasks.removeValue(forKey: id)?.cancel()
        videoTasks.removeValue(forKey: id)?.cancel()
        stoppedVideos.remove(id)
        finalizingVideos.remove(id)
        pausing[id] = nil
        approved.remove(id)
        items.removeAll { $0.id == id }
        save()
        schedule()
    }

    func clearQueue() {
        archivedImages = galleryImages
        let active = Array(tasks.values)
        stopVideoTasks()
        items.removeAll()
        tasks.removeAll()
        videoTasks.removeAll()
        stoppedVideos.removeAll()
        finalizingVideos.removeAll()
        pausing.removeAll()
        approved.removeAll()
        privateHeaders.removeAll()
        privateStreamCookies.removeAll()
        isPaused = false
        active.forEach { $0.cancel() }
        save()
    }

    func stopVideoTasks() {
        videoTasks.values.forEach { $0.cancel() }
    }

    func saveStream(_ id: UUID) {
        guard case .stream(let stream)? = videoTasks[id], !stoppedVideos.contains(id),
              finalizingVideos.insert(id).inserted else { return }
        stream.stopAndSave()
    }

    private func tick() {
        for index in items.indices where items[index].status == .downloading {
            let id = items[index].id
            let received: Int64
            let expected: Int64
            if let task = tasks[id] {
                received = task.countOfBytesReceived
                expected = task.countOfBytesExpectedToReceive
            } else if let video = videoTasks[id] {
                (received, expected) = video.progress
            } else {
                continue
            }
            if items[index].received != received { items[index].received = received }
            if items[index].expected != expected { items[index].expected = expected }
        }
        schedule()
    }

    private func schedule() {
        guard !isPaused, tasks.count + videoTasks.count < connections else { return }
        let now = Date()
        for index in items.indices {
            guard tasks.count + videoTasks.count < connections else { break }
            let item = items[index]
            guard tasks[item.id] == nil, videoTasks[item.id] == nil, autoStart || approved.contains(item.id),
                  item.status == .queued ||
                    (item.status == .retrying && (item.retryDate ?? .distantPast) <= now) else { continue }
            start(index)
        }
    }

    private func start(_ index: Int) {
        let item = items[index]
        items[index].status = .downloading
        items[index].retryDate = nil
        items[index].error = nil
        if item.resumeData == nil {
            items[index].received = 0
            items[index].expected = 0
        }
        if item.media.videoPage == true {
            startExtractedVideo(item)
            return
        }
        if let format = item.media.streamFormat {
            startStream(item, format: format)
            return
        }
        let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] location, response, error in
            let result = Self.finish(item, location: location, response: response, error: error)
            Task { @MainActor in self?.completed(item.id, result) }
        }
        let task: URLSessionDownloadTask
        if let data = item.resumeData {
            task = session.downloadTask(withResumeData: data, completionHandler: completion)
        } else {
            var request = URLRequest(url: item.media.url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let source = item.media.source {
                var referer = URLComponents(url: source, resolvingAgainstBaseURL: false)
                if source.host != item.media.url.host {
                    referer?.path = "/"
                    referer?.query = nil
                }
                request.setValue(referer?.string, forHTTPHeaderField: "Referer")
            }
            for (key, value) in item.media.requestHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            for (key, value) in privateHeaders[item.media.url] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            task = session.downloadTask(with: request, completionHandler: completion)
        }
        tasks[item.id] = task
        save()
        task.resume()
    }

    private func startStream(_ item: Transfer, format: StreamFormat) {
        let browserCookies = session.configuration.httpCookieStorage?.cookies ?? []
        var cookies: [String: StreamCookie] = [:]
        for cookie in browserCookies.map(StreamCookie.init) + (privateStreamCookies[item.media.url] ?? []) {
            cookies[cookie.key] = cookie
        }
        do {
            let stream = try VideoProcess(media: item.media, format: format, cookies: Array(cookies.values),
                                          defaultUserAgent: userAgent) { [weak self] location, status, exited in
                Task { @MainActor in
                    if let self {
                        self.streamCompleted(item, location: location, status: status, exited: exited)
                    } else {
                        VideoProcess.removeTemporaryFiles(for: location)
                    }
                }
            }
            videoTasks[item.id] = .stream(stream)
            save()
        } catch {
            completed(item.id, TransferResult(error: error.localizedDescription), scheduleNext: false)
        }
    }

    private func startExtractedVideo(_ item: Transfer) {
        let hosts = YTDLPIntegration.cookieHosts(for: item.media.url)
        let browserCookies = session.configuration.httpCookieStorage?.cookies ?? []
        var cookies: [String: StreamCookie] = [:]
        for cookie in browserCookies.map(StreamCookie.init) + (privateStreamCookies[item.media.url] ?? [])
        where hosts.contains(where: cookie.matches) {
            cookies[cookie.key] = cookie
        }
        do {
            let download = try ExtractedVideoDownload(media: item.media, cookies: Array(cookies.values)) { [weak self] result in
                if let self {
                    self.extractedVideoCompleted(item, result: result)
                } else {
                    try? FileManager.default.removeItem(at: result.directory)
                }
            }
            videoTasks[item.id] = .extracted(download)
            save()
        } catch {
            completed(item.id, TransferResult(error: error.localizedDescription), scheduleNext: false)
        }
    }

    private func extractedVideoCompleted(_ item: Transfer, result: ExtractedVideoResult) {
        guard videoTasks[item.id] != nil else {
            try? FileManager.default.removeItem(at: result.directory)
            return
        }
        if stoppedVideos.remove(item.id) != nil {
            try? FileManager.default.removeItem(at: result.directory)
            videoTasks[item.id] = nil
            schedule()
            return
        }
        guard let output = result.output else {
            try? FileManager.default.removeItem(at: result.directory)
            let error = result.error ?? "yt-dlp could not finish the download."
            let permanent = ["sign-in", "DRM", "unavailable", "does not recognize"].contains { error.contains($0) }
            finishVideo(item.id, TransferResult(error: error, retryable: !permanent))
            return
        }
        finalizingVideos.insert(item.id)
        let suffix = "." + output.pathExtension.lowercased()
        let filename = item.media.name.lowercased().hasSuffix(suffix) ? item.media.name : item.media.name + suffix
        let directory = result.directory
        Task.detached(priority: .utility) { [weak self] in
            let saved = Self.saveFile(item, location: output, filename: filename)
            try? FileManager.default.removeItem(at: directory)
            await self?.finishVideo(item.id, saved)
        }
    }

    private func streamCompleted(_ item: Transfer, location: URL, status: Int32, exited: Bool) {
        guard videoTasks[item.id] != nil else {
            VideoProcess.removeTemporaryFiles(for: location)
            return
        }
        let finalized = finalizingVideos.contains(item.id)
        if stoppedVideos.remove(item.id) != nil {
            VideoProcess.removeTemporaryFiles(for: location)
            videoTasks[item.id] = nil
            schedule()
            return
        }
        let bytes = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if exited && (status == 0 || (finalized && status == 255)) && bytes > 0 {
            finalizingVideos.insert(item.id)
            Task.detached(priority: .utility) { [weak self] in
                let result = VideoProcess.containsMedia(location)
                    ? Self.saveFile(item, location: location, filename: item.media.name)
                    : TransferResult(error: "FFmpeg stopped before a playable video was written.", retryable: !finalized)
                VideoProcess.removeTemporaryFiles(for: location)
                await self?.finishVideo(item.id, result)
            }
        } else {
            VideoProcess.removeTemporaryFiles(for: location)
            finishVideo(item.id, TransferResult(error: "FFmpeg could not save this stream. Check that it plays in Site Browser and that your sign-in is current.",
                                                 retryable: !finalized))
        }
    }

    private func finishVideo(_ id: UUID, _ result: TransferResult) {
        videoTasks[id] = nil
        finalizingVideos.remove(id)
        completed(id, result)
    }

    private nonisolated static func finish(_ item: Transfer, location: URL?, response: URLResponse?, error: Error?) -> TransferResult {
        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                return TransferResult(error: error.localizedDescription)
            }
            let retryable = error.domain == NSURLErrorDomain && ![
                NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorUserAuthenticationRequired,
                NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted
            ].contains(error.code)
            return TransferResult(error: error.localizedDescription,
                                  resumeData: error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                                  retryable: retryable || item.resumeData != nil)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = [401, 403].contains(http.statusCode) ? " Sign in through the site browser and try again." : ""
            return TransferResult(error: "HTTP \(http.statusCode).\(detail)", retryable: [408, 425, 429].contains(http.statusCode) || http.statusCode >= 500)
        }
        if response?.mimeType == "text/html", item.media.kind != .file {
            return TransferResult(error: "The server returned a web page. Check the link or sign in through the site browser.")
        }
        if let stream = StreamFormat(mimeType: response?.mimeType) {
            return TransferResult(stream: stream)
        }
        guard let location else { return TransferResult(error: "The server returned no file.", retryable: true) }
        let name = item.media.suggestedFilename ?? response?.suggestedFilename ?? item.media.url.displayFilename
        return saveFile(item, location: location, filename: name, mime: response?.mimeType)
    }

    private nonisolated static func saveFile(_ item: Transfer, location: URL, filename: String, mime: String? = nil) -> TransferResult {
        let files = FileManager.default
        do {
            try files.createDirectory(at: item.folder, withIntermediateDirectories: true)
            var name = filename.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_")
            if name.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty { name = "download" }
            if (name as NSString).pathExtension.isEmpty, let mime,
               let suffix = UTType(mimeType: mime)?.preferredFilenameExtension {
                name += "." + suffix
            }
            let base = (name as NSString).deletingPathExtension
            let suffix = (name as NSString).pathExtension
            var index = 1
            while true {
                let filename = index == 1 ? name : base + " (\(index))" + (suffix.isEmpty ? "" : "." + suffix)
                let destination = item.folder.appending(path: filename)
                do {
                    try files.moveItem(at: location, to: destination)
                    return TransferResult(output: destination)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    index += 1
                }
            }
        } catch {
            return TransferResult(error: "Could not save the file. " + error.localizedDescription)
        }
    }

    private func completed(_ id: UUID, _ result: TransferResult, scheduleNext: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if pausing[id] != nil, result.output == nil {
            pausing[id]?.finished = true
            finishPause(id)
            return
        }
        tasks[id] = nil
        pausing[id] = nil
        if let stream = result.stream {
            items[index].media.stream = stream
            items[index].media.kind = .video
            items[index].resumeData = nil
            items[index].status = isPaused ? .paused : .queued
        } else if let output = result.output {
            approved.remove(id)
            privateHeaders[items[index].media.url] = nil
            privateStreamCookies[items[index].media.url] = nil
            items[index].status = .complete
            items[index].output = output
            items[index].resumeData = nil
            if let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                items[index].received = Int64(size)
                items[index].expected = Int64(size)
            }
        } else {
            items[index].error = result.error
            items[index].resumeData = result.resumeData
            if result.retryable, items[index].attempts < retries {
                items[index].attempts += 1
                items[index].status = .retrying
                items[index].retryDate = Date().addingTimeInterval(pow(2, Double(items[index].attempts)))
            } else {
                approved.remove(id)
                items[index].status = .failed
            }
        }
        save()
        if scheduleNext { schedule() }
    }

    private func finishPause(_ id: UUID) {
        guard let request = pausing[id], request.receivedResumeData, request.finished,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        tasks[id] = nil
        pausing[id] = nil
        items[index].resumeData = request.data
        save()
        schedule()
    }

    private struct State: Codable {
        var paused: Bool
        var items: [Transfer]
        var archivedImages: [Transfer]?
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let persistable = items.map { item in
                var item = item
                if privateHeaders[item.media.url] != nil { item.resumeData = nil }
                return item
            }
            let data = try JSONEncoder().encode(State(paused: isPaused, items: persistable, archivedImages: archivedImages))
            try data.write(to: stateFile, options: .atomic)
        } catch {
            storageError = "The queue could not be saved. " + error.localizedDescription
        }
    }
}
