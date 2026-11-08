import AppKit
import Darwin
import Foundation
import Observation
import Security
import UniformTypeIdentifiers

struct GallerySite: Decodable, Identifiable {
    let id: String
    let hosts: [String]
    let examples: [String: String]
    let oauth: Bool
    let linkedImages: Bool?

    var name: String {
        switch id {
        case "twitter": "X / Twitter"
        case "deviantart": "DeviantArt"
        case "pixiv": "Pixiv"
        case "smugmug": "SmugMug"
        case "vk": "VK"
        case "youtube", "youtubeytbe": "YouTube"
        case "tiktok": "TikTok"
        case "soundcloud": "SoundCloud"
        case "dailymotion": "Dailymotion"
        default: id.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func bestMatch(for url: URL, in sites: [Self]) -> Self? {
        guard let host = url.host?.lowercased() else { return nil }
        var best: Self?
        var matchLength = 0
        for site in sites {
            for domain in site.hosts where domain.count > matchLength &&
                (host == domain || host.hasSuffix("." + domain)) {
                best = site
                matchLength = domain.count
            }
        }
        return best
    }
}

struct GalleryCatalog: Decodable {
    let version: String
    let sites: [GallerySite]
}

struct GalleryEvent: Decodable, Sendable {
    let event: String
    let url: URL?
    let source: URL?
    let category: String?
    let cookieDomain: String?
    let headers: [String: String]?
    let filename: String?
    let `extension`: String?
    let status: Int?
    let skipped: Int?
    let manual: Bool?
    let options: [String: String]?
    let message: String?
    let stream: StreamFormat?
    let galleryTitle: String?
    let streamCookies: [StreamCookie]?
    let videoPage: Bool?
    let kind: MediaKind?
    let bytes: Int64?
    let total: Int64?
}

private struct GalleryCookie: Encodable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Int64?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain.lowercased()
        path = cookie.path
        secure = cookie.isSecure
        expires = cookie.expiresDate.map { Int64($0.timeIntervalSince1970) }
    }

    init?(line: Substring) {
        let httpOnly = line.hasPrefix("#HttpOnly_")
        guard !line.hasPrefix("#") || httpOnly else { return nil }
        let columns = line.dropFirst(httpOnly ? "#HttpOnly_".count : 0)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 7, let expiration = Int64(columns[4]),
              !columns[0].isEmpty, !columns[5].isEmpty,
              columns[2].hasPrefix("/"), ["TRUE", "FALSE"].contains(columns[1]),
              ["TRUE", "FALSE"].contains(columns[3]) else { return nil }
        let bareDomain = columns[0].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard let address = URL.web("https://" + bareDomain), address.host == bareDomain,
              address.path.isEmpty, address.port == nil, address.query == nil else { return nil }
        domain = columns[1] == "TRUE" ? "." + bareDomain : bareDomain
        path = String(columns[2])
        secure = columns[3] == "TRUE"
        expires = expiration > 0 ? expiration : nil
        name = String(columns[5])
        value = String(columns[6])
    }

    var key: String { "\(domain)\t\(path)\t\(name)" }

    var streamCookie: StreamCookie {
        StreamCookie(name: name, value: value, domain: domain, path: path, secure: secure, expires: expires)
    }

    func matches(_ host: String) -> Bool {
        if let expires, expires <= Int64(Date().timeIntervalSince1970) { return false }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return !bare.isEmpty && (host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)))
    }
}

private enum GalleryError: LocalizedError {
    case missingRuntime, processFailed, cookieFormat, credentials(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingRuntime: "The bundled extraction runtime is missing."
        case .processFailed: "The extractor stopped before it could finish."
        case .cookieFormat: "Choose a Netscape cookies.txt file with at least one cookie and a size under 2 MB."
        case .credentials(let status): "macOS Keychain could not update the account (\(status))."
        }
    }
}

struct GalleryProcess {
    static var runtime: URL? { Bundle.main.resourceURL?.appending(path: "GalleryRuntime", directoryHint: .isDirectory) }

    let events: AsyncThrowingStream<GalleryEvent, Error>
    private let process: Process
    private let input: FileHandle
    private let isolatedGroup: Bool

    init(script: String = "bridge.py", isolatedGroup: Bool = false) throws {
        guard let root = Self.runtime else { throw GalleryError.missingRuntime }
        let executable = root.appending(path: "bin/python3")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw GalleryError.missingRuntime }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["-I", "-B", "-S", "-u", root.appending(path: script).path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.process = process
        self.isolatedGroup = isolatedGroup
        input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        events = AsyncThrowingStream { continuation in
            continuation.onTermination = { reason in
                if case .cancelled = reason { Self.terminate(process, isolatedGroup: isolatedGroup) }
            }
            Task.detached(priority: .utility) {
                defer { try? reader.close() }
                var pending = Data()
                let decoder = JSONDecoder()
                do {
                    // Read what is available. The worker can wait for input after sending one line.
                    while case let data = reader.availableData, !data.isEmpty {
                        pending.append(data)
                        while let newline = pending.firstIndex(of: 10) {
                            let line = pending[..<newline]
                            if let event = try? decoder.decode(GalleryEvent.self, from: line) {
                                continuation.yield(event)
                            }
                            pending.removeSubrange(...newline)
                        }
                        guard pending.count < 2 * 1024 * 1024 else { throw GalleryError.processFailed }
                    }
                    process.waitUntilExit()
                    if process.terminationStatus != 0 { throw GalleryError.processFailed }
                    continuation.finish()
                } catch {
                    Self.terminate(process, isolatedGroup: isolatedGroup)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func send<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try input.write(contentsOf: data)
    }

    func submitCode(_ code: String) throws {
        let line = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains(where: \.isNewline), line.utf8.count < 8192 else { return }
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        Self.terminate(process, isolatedGroup: isolatedGroup)
        try? input.close()
    }

    private static func terminate(_ process: Process, isolatedGroup: Bool) {
        guard process.isRunning else { return }
        if isolatedGroup {
            let pid = process.processIdentifier
            let target = getpgid(pid) == pid ? -pid : pid
            _ = kill(target, SIGKILL)
        } else {
            process.terminate()
        }
    }
}

enum CredentialKeychain {
    private static let galleryService = "Media Harbor gallery-dl OAuth"
    private static func query(_ account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load(_ account: String, service: String = galleryService) -> [String: String]? {
        var request = query(account, service: service)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    static func save(_ values: [String: String], for account: String, service: String = galleryService) throws {
        let query = query(account, service: service)
        let values = [kSecValueData as String: try JSONEncoder().encode(values)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GalleryError.credentials(status) }
    }

    static func remove(_ account: String, service: String = galleryService) throws {
        let status = SecItemDelete(query(account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GalleryError.credentials(status) }
    }
}

struct GalleryScanOutcome {
    var count = 0
    var note: String?
}

@MainActor @Observable
final class GalleryIntegration {
    let sites: [GallerySite]
    let version: String
    private var importedCookies: [GalleryCookie] = []
    private var authorization: GalleryProcess?
    private var authorizationTask: Task<Void, Never>?
    private(set) var authorizationURL: URL?
    private(set) var waitingForCode = false
    private(set) var authorizing = false
    private(set) var authMessage = ""
    private(set) var cookieMessage = ""
    private(set) var accounts: Set<String> = [] {
        didSet { UserDefaults.standard.set(accounts.sorted(), forKey: "galleryOAuthAccounts") }
    }

    init() {
        let catalog = GalleryProcess.runtime.flatMap { try? Data(contentsOf: $0.appending(path: "sites.json")) }
            .flatMap { try? JSONDecoder().decode(GalleryCatalog.self, from: $0) }
        sites = catalog?.sites ?? []
        version = catalog?.version ?? ""
        accounts = Set(UserDefaults.standard.stringArray(forKey: "galleryOAuthAccounts") ?? [])
    }

    var importedCookieCount: Int { importedCookies.count }

    func hasImportedCookies(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return importedCookies.contains { $0.matches(host) }
    }

    func importedStreamCookies(for urls: [URL]) -> [URL: [StreamCookie]] {
        var result: [URL: [StreamCookie]] = [:]
        for url in urls {
            guard let host = url.host?.lowercased() else { continue }
            let cookies = importedCookies.filter { $0.matches(host) }.map(\.streamCookie)
            if !cookies.isEmpty { result[url] = cookies }
        }
        return result
    }

    func videoCookies(for url: URL, browserCookies: [HTTPCookie] = []) -> [StreamCookie] {
        let hosts = YTDLPIntegration.cookieHosts(for: url)
        var cookies: [String: StreamCookie] = [:]
        for cookie in browserCookies.map(StreamCookie.init) + importedCookies.map(\.streamCookie)
        where hosts.contains(where: cookie.matches) {
            cookies[cookie.key] = cookie
        }
        return Array(cookies.values)
    }

    func importCookies(from url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else {
                throw GalleryError.cookieFormat
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let cookies = text.split(whereSeparator: \.isNewline).compactMap(GalleryCookie.init(line:))
            guard !cookies.isEmpty else { throw GalleryError.cookieFormat }
            var unique = Dictionary(uniqueKeysWithValues: importedCookies.map { ($0.key, $0) })
            for cookie in cookies { unique[cookie.key] = cookie }
            importedCookies = Array(unique.values)
            cookieMessage = "Loaded \(cookies.count.formatted()) cookies for this app session."
        } catch {
            cookieMessage = error.localizedDescription
        }
    }

    func clearImportedCookies() {
        importedCookies = []
        cookieMessage = "Imported cookies cleared."
    }

    func scan(_ url: URL, browserCookies: [HTTPCookie], linkedImages: [URL]? = nil,
              onMedia: (MediaCandidate, [String: String], [StreamCookie]) -> Void) async throws -> GalleryScanOutcome {
        struct Request: Encodable {
            let command = "scan"
            let url: URL
            let mastodon: Bool
            let linkedImages: [URL]?
        }
        struct Credentials: Encodable {
            let cookies: [GalleryCookie]
            let options: [String: String]
        }
        let host = url.host?.lowercased() ?? ""
        let process = try GalleryProcess()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(linkedImages == nil ? 90 : 180))
            if !Task.isCancelled { process.stop() }
        }
        defer {
            timeout.cancel()
            process.stop()
        }
        try process.send(Request(url: url, mastodon: accounts.contains("mastodon:" + host), linkedImages: linkedImages))
        var outcome = GalleryScanOutcome()
        var activeAccount: String?
        var activeOptions: [String: String] = [:]
        do {
            for try await event in process.events {
                try Task.checkCancellation()
                switch event.event {
                case "match":
                    let provider = event.category ?? ""
                    var hosts = Set([host])
                    if let domain = event.cookieDomain?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !domain.isEmpty {
                        hosts.insert(domain.lowercased())
                    }
                    if provider == "twitter" { hosts.insert("x.com") }
                    var cookies: [String: GalleryCookie] = [:]
                    for cookie in browserCookies.map(GalleryCookie.init) + importedCookies
                    where hosts.contains(where: cookie.matches) {
                        cookies[cookie.key] = cookie
                    }
                    let account = Self.account(provider, instance: host)
                    let options = accounts.contains(account) ? CredentialKeychain.load(account) ?? [:] : [:]
                    activeAccount = account
                    activeOptions = options
                    try process.send(Credentials(cookies: Array(cookies.values), options: options))
                case "refreshed":
                    if let account = activeAccount, accounts.contains(account),
                       CredentialKeychain.load(account) == activeOptions, let token = event.options?["refresh-token"] {
                        var updated = activeOptions
                        updated["refresh-token"] = token
                        do {
                            try CredentialKeychain.save(updated, for: account)
                            activeOptions = updated
                        } catch {
                            outcome.note = "The refreshed authorization could not be saved in Keychain."
                        }
                    }
                case "media":
                    guard let address = event.url.flatMap({ URL.web($0.absoluteString) }) else { continue }
                    let ext = event.extension?.lowercased()
                    let stream = event.stream ?? StreamFormat(url: address)
                    let kind = stream != nil || event.videoPage == true ? MediaKind.video : ext.flatMap { MediaKind.detect(URL(filePath: "file." + $0)) }
                        ?? MediaKind.detect(address) ?? .file
                    var filename = event.filename
                    if event.videoPage != true, let ext, ext.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil,
                       let name = filename, !name.isEmpty, !name.lowercased().hasSuffix("." + ext) {
                        filename = name + "." + ext
                    }
                    onMedia(MediaCandidate(url: address, source: event.source ?? url, kind: kind, suggestedFilename: filename,
                                           stream: stream, galleryTitle: event.galleryTitle, videoPage: event.videoPage),
                            event.headers ?? [:], event.streamCookies ?? [])
                    outcome.count += 1
                case "done":
                    if let status = event.status, status & 16 != 0 {
                        outcome.note = "The site requires a valid sign-in. Sign in through Site Browser or use Templates → Authentication."
                    } else if let status = event.status, status & 8 != 0 {
                        outcome.note = "The site blocked the gallery-dl request."
                    } else if let status = event.status, status != 0 {
                        outcome.note = "gallery-dl could not read every result from this page."
                    } else if let skipped = event.skipped, skipped > 0, outcome.note == nil {
                        outcome.note = "\(skipped.formatted()) items requiring a separate extractor were skipped."
                    }
                    return outcome
                case "unsupported": return outcome
                case "error":
                    outcome.note = event.message
                    return outcome
                default: continue
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome.note = error.localizedDescription
        }
        try Task.checkCancellation()
        return outcome
    }

    static func account(_ provider: String, instance: String) -> String {
        provider == "mastodon" ? provider + ":" + instance : provider
    }

    func resetAuthorizationMessage() {
        if !authorizing { authMessage = "" }
    }

    func authorize(_ provider: String, instance: String, client: String, secret: String) {
        guard !authorizing else { return }
        let host = instance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "mastodon" {
            guard let url = URL.web("https://" + host), url.host == host,
                  url.path.isEmpty, url.query == nil, url.port == nil, host.contains(".") else {
                authMessage = "Enter a Mastodon hostname, such as mastodon.social."
                return
            }
        }
        let oauth1 = ["flickr", "smugmug", "tumblr"].contains(provider)
        if provider == "flickr" && (client.isEmpty || secret.isEmpty) {
            authMessage = "Flickr requires your Flickr API key and secret for gallery-dl OAuth."
            return
        }
        var options: [String: String] = [:]
        if !client.isEmpty { options[oauth1 ? "api-key" : "client-id"] = client }
        if !secret.isEmpty { options[oauth1 ? "api-secret" : "client-secret"] = secret }

        authorizing = true
        authorizationURL = nil
        waitingForCode = false
        authMessage = "Preparing authorization…"
        authorizationTask = Task {
            defer {
                authorization?.stop()
                authorization = nil
                authorizing = false
                authorizationURL = nil
                waitingForCode = false
                authorizationTask = nil
            }
            do {
                struct Request: Encodable {
                    let command = "oauth"
                    let provider: String
                    let instance: String
                    let options: [String: String]
                }
                let process = try GalleryProcess()
                authorization = process
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(330))
                    if !Task.isCancelled { process.stop() }
                }
                defer { timeout.cancel() }
                try process.send(Request(provider: provider, instance: host, options: options))
                for try await event in process.events {
                    try Task.checkCancellation()
                    switch event.event {
                    case "authorize":
                        guard let url = event.url, url.scheme == "https", URL.web(url.absoluteString) != nil else {
                            throw GalleryError.processFailed
                        }
                        authorizationURL = url
                        waitingForCode = event.manual == true
                        authMessage = waitingForCode
                            ? "Sign in to Pixiv. Paste the code from the final callback in your browser’s Network inspector. The code expires quickly."
                            : "Complete authorization in your browser. Paste the callback URL below if the browser does not return automatically."
                        NSWorkspace.shared.open(url)
                    case "connected":
                        guard let options = event.options else { throw GalleryError.processFailed }
                        let account = Self.account(provider, instance: host)
                        try CredentialKeychain.save(options, for: account)
                        accounts.insert(account)
                        authMessage = "Account connected."
                        return
                    case "inputError": authMessage = event.message ?? "Check the callback URL."
                    case "error":
                        authMessage = event.message ?? "The provider did not grant access."
                        return
                    default: continue
                    }
                }
                try Task.checkCancellation()
                throw GalleryError.processFailed
            } catch is CancellationError {
                authMessage = "Authorization canceled."
            } catch {
                authMessage = Task.isCancelled ? "Authorization canceled." : error.localizedDescription
            }
        }
    }

    func submitAuthorizationCode(_ value: String) {
        do { try authorization?.submitCode(value) }
        catch { authMessage = "The authorization session has ended. Try again." }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorization?.stop()
    }

    func disconnect(_ account: String) {
        do {
            try CredentialKeychain.remove(account)
            accounts.remove(account)
            authMessage = "Account disconnected from Media Harbor."
        } catch {
            authMessage = error.localizedDescription
        }
    }
}
