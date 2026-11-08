import Darwin
import Foundation

struct StreamCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Int64?

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain.lowercased(),
                  path: cookie.path, secure: cookie.isSecure,
                  expires: cookie.expiresDate.map { Int64($0.timeIntervalSince1970) })
    }

    init(name: String, value: String, domain: String, path: String, secure: Bool, expires: Int64?) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.expires = expires
    }

    var key: String { "\(domain)\t\(path)\t\(name)" }

    func matches(_ host: String) -> Bool {
        if let expires, expires <= Int64(Date().timeIntervalSince1970) { return false }
        let base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return !base.isEmpty && (host == base || (domain.hasPrefix(".") && host.hasSuffix("." + base)))
    }

    func optionLine(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), matches(host),
              (!secure || url.scheme == "https"),
              !name.isEmpty, !name.contains("="), path.hasPrefix("/"),
              [name, value, domain, path].allSatisfy({ !$0.contains(";") && !$0.contains(where: \.isNewline) }) else { return nil }
        return "\(name)=\(value); domain=\(domain); path=\(path)" + (secure ? "; secure=1" : "")
    }
}

struct VideoProcess {
    let output: URL
    private let process: Process

    init(media: MediaCandidate, format: StreamFormat, cookies: [StreamCookie], defaultUserAgent: String,
         completion: @escaping @Sendable (URL, Int32, Bool) -> Void) throws {
        guard let binary = Bundle.main.resourceURL?.appending(path: "VideoRuntime/ffmpeg"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw VideoError.missingFFmpeg
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaHarbor-Stream-" + UUID().uuidString, directoryHint: .isDirectory)
        let output = directory.appending(path: "recording.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let process = Process()
            process.executableURL = binary
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let encrypted = media.url.scheme == "https"
            let protocols = encrypted ? "https,tls,tcp,crypto" : "http,https,tls,tcp,crypto"
            let userAgent = media.requestHeaders?.first { $0.key.lowercased() == "user-agent" }?.value
                ?? defaultUserAgent
            var arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-protocol_whitelist", protocols, "-rw_timeout", "30000000",
                "-user_agent", userAgent, "-f", format.rawValue
            ]
            if let referer = media.source ?? media.collectionURL,
               var origin = URLComponents(url: referer, resolvingAgainstBaseURL: false) {
                origin.path = "/"
                origin.query = nil
                origin.fragment = nil
                if let value = origin.string { arguments += ["-referer", value] }
            }
            let lines = cookies.compactMap { $0.optionLine(for: media.url) }
            if !lines.isEmpty {
                let cookieFile = directory.appending(path: "cookies")
                try Data(lines.joined(separator: "\n").utf8).write(to: cookieFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookieFile.path)
                arguments += ["-/cookies", cookieFile.path]
            }
            arguments += [
                "-i", media.url.absoluteString, "-sn", "-dn", "-c", "copy",
                "-movflags", "+hybrid_fragmented+frag_keyframe", "-frag_duration", "1000000",
                "-flush_packets", "1", "-f", "mp4", output.path
            ]
            process.arguments = arguments
            process.terminationHandler = { process in
                completion(output, process.terminationStatus, process.terminationReason == .exit)
            }
            try process.run()
            self.process = process
            self.output = output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var bytesWritten: Int64 {
        Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func cancel() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent().appending(path: "cookies"))
    }

    func stopAndSave() {
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            // FFmpeg needs a second interrupt if a live playlist is still waiting for a segment.
            if process.isRunning { process.interrupt() }
        }
    }

    static func removeTemporaryFiles(for output: URL) {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }

    static func containsMedia(_ output: URL) -> Bool {
        guard let reader = try? FileHandle(forReadingFrom: output) else { return false }
        defer { try? reader.close() }
        guard let size = try? reader.seekToEnd() else { return false }
        var offset: UInt64 = 0
        var hasMovie = false
        var hasSamples = false
        while size - offset >= 8 {
            do {
                try reader.seek(toOffset: offset)
                guard let header = try reader.read(upToCount: 8), header.count == 8 else { return false }
                let type = String(decoding: header.suffix(4), as: UTF8.self)
                var boxSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                var headerSize: UInt64 = 8
                if boxSize == 1 {
                    guard let extended = try reader.read(upToCount: 8), extended.count == 8 else { return false }
                    boxSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    headerSize = 16
                } else if boxSize == 0 {
                    boxSize = size - offset
                }
                guard boxSize >= headerSize, boxSize <= size - offset else { return false }
                hasMovie = hasMovie || (type == "moov" && boxSize > headerSize)
                hasSamples = hasSamples || (type == "mdat" && boxSize > headerSize)
                if hasMovie && hasSamples { return true }
                offset += boxSize
            } catch {
                return false
            }
        }
        return false
    }

    private enum VideoError: LocalizedError {
        case missingFFmpeg
        var errorDescription: String? { "The bundled FFmpeg executable is missing." }
    }
}
