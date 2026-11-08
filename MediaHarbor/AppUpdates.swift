import AppKit
import CryptoKit
import Darwin
import Observation
import SwiftUI

private final class ReleaseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", let host = request.url?.host,
              host == "api.github.com" || host == "release-assets.githubusercontent.com" else {
            completionHandler(nil)
            return
        }
        var request = request
        if host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

@MainActor @Observable
final class AppUpdates {
    struct Release: Decodable {
        struct Asset: Decodable {
            let id: Int
            let name: String
            let size: Int
        }

        let tag_name: String
        let assets: [Asset]
        var version: String { String(tag_name.drop(while: { $0 == "v" })) }
    }

    private enum UpdateError: LocalizedError {
        case access, response, archive, signature, invalidApp, installation, busy

        var errorDescription: String? {
            switch self {
            case .access: "Enter a GitHub token with read access to the MediaHarbor repository."
            case .response: "GitHub could not provide the latest release."
            case .archive: "This release is missing a complete update archive and signature."
            case .signature: "The update signature could not be verified."
            case .invalidApp: "The archive does not contain the expected Media Harbor build."
            case .installation: "Media Harbor could not replace this copy. Open a writable copy of the app to update it."
            case .busy: "Wait for the current scan and downloads to finish before installing."
            }
        }
    }

    private static let repository = URL(string: "https://api.github.com/repos/TMRJIJ/MediaHarbor")!
    static let releasesPage = URL(string: "https://github.com/TMRJIJ/MediaHarbor/releases")!
    private static let service = "Media Harbor GitHub updates"
    private static let archiveName = "Media.Harbor.zip"
    private static let signatureName = "Media.Harbor.zip.sig"
    private let session: URLSession
    private var checkedThisLaunch = false
    private(set) var hasToken = UserDefaults.standard.bool(forKey: "githubUpdateConnected")
    private(set) var message = ""
    private(set) var working = false
    private(set) var available: Release?
    var automatic = UserDefaults.standard.bool(forKey: "automaticAppUpdates") {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticAppUpdates") }
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: ReleaseRedirects(), delegateQueue: nil)
    }

    func saveToken(_ input: String) {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            message = UpdateError.access.localizedDescription
            return
        }
        do {
            try CredentialKeychain.save(["token": token], for: "github", service: Self.service)
            hasToken = true
            UserDefaults.standard.set(true, forKey: "githubUpdateConnected")
            message = "GitHub token saved in Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    func removeToken() {
        do {
            try CredentialKeychain.remove("github", service: Self.service)
            hasToken = false
            automatic = false
            available = nil
            UserDefaults.standard.removeObject(forKey: "githubUpdateConnected")
            message = "GitHub token removed."
        } catch {
            message = error.localizedDescription
        }
    }

    func checkOnLaunch(canInstall: () -> Bool) async {
        guard automatic, hasToken, !checkedThisLaunch else { return }
        checkedThisLaunch = true
        await check()
        if automatic, available != nil, canInstall() { await install(canInstall: { self.automatic && canInstall() }) }
    }

    func check() async {
        guard !working else { return }
        working = true
        defer { working = false }
        message = "Checking GitHub for app and dependency updates…"
        available = nil
        do {
            let (data, response) = try await session.data(for: request("releases/latest", accept: "application/vnd.github+json"))
            try Self.checkResponse(response)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard release.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  release.version.compare(installed, options: .numeric) == .orderedDescending else {
                message = "Media Harbor and its bundled dependencies are up to date."
                return
            }
            guard release.assets.contains(where: { $0.name == Self.archiveName }),
                  release.assets.contains(where: { $0.name == Self.signatureName }) else { throw UpdateError.archive }
            available = release
            message = "Media Harbor \(release.version) is available with its bundled dependencies."
        } catch {
            message = error.localizedDescription
        }
    }

    func install(canInstall: () -> Bool) async {
        guard !working, let release = available else { return }
        guard canInstall() else { message = UpdateError.busy.localizedDescription; return }
        working = true
        defer { working = false }
        message = "Downloading the signed Media Harbor update…"
        do {
            guard let zip = release.assets.first(where: { $0.name == Self.archiveName }),
                  let sig = release.assets.first(where: { $0.name == Self.signatureName }),
                  (1...400 * 1024 * 1024).contains(zip.size), sig.size == 64 else { throw UpdateError.archive }
            let (signature, response) = try await session.data(for: request("releases/assets/\(sig.id)", accept: "application/octet-stream"))
            try Self.checkResponse(response)
            let (archive, download) = try await session.download(for: request("releases/assets/\(zip.id)", accept: "application/octet-stream"))
            defer { try? FileManager.default.removeItem(at: archive) }
            try Self.checkResponse(download)
            guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == zip.size else { throw UpdateError.archive }

            message = "Verifying the update…"
            let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
            guard let identifier = Bundle.main.bundleIdentifier,
                  let key = Bundle.main.object(forInfoDictionaryKey: "MediaHarborUpdateKey") as? String else { throw UpdateError.signature }
            let staging = try await Task.detached(priority: .utility) {
                try Self.stage(archive, signature: signature, key: key, nextVersion: release.version, identifier: identifier, app: app)
            }.value
            do {
                guard canInstall() else { throw UpdateError.busy }
                try Self.replace(app, with: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
                throw error
            }
            NSApplication.shared.terminate(nil)
        } catch {
            message = error.localizedDescription
        }
    }

    private func request(_ path: String, accept: String) throws -> URLRequest {
        guard let token = CredentialKeychain.load("github", service: Self.service)?["token"] else { throw UpdateError.access }
        var request = URLRequest(url: Self.repository.appending(path: path))
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private nonisolated static func checkResponse(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw UpdateError.response }
        if [401, 403, 404].contains(status) { throw UpdateError.access }
        guard status == 200 else { throw UpdateError.response }
    }

    private nonisolated static func stage(_ archive: URL, signature: Data, key: String, nextVersion: String,
                                         identifier: String, app: URL) throws -> URL {
        guard signature.count == 64, let key = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { throw UpdateError.signature }
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
        guard publicKey.isValidSignature(signature, for: Data(digest)) else { throw UpdateError.signature }
        let files = FileManager.default
        let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            let staged = directory.appending(path: "Media Harbor.app", directoryHint: .isDirectory)
            guard let bundle = Bundle(url: staged), bundle.bundleIdentifier == identifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == nextVersion,
                  bundle.executableURL != nil else { throw UpdateError.invalidApp }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            return staged
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidApp }
    }

    private static func replace(_ app: URL, with staged: URL) throws {
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", """
        while kill -0 "$1" 2>/dev/null; do sleep 1; done
        if /usr/bin/open -n "$2"; then /bin/rm -rf "$3"; fi
        """, "media-harbor-relaunch", String(getpid()), app.path, staged.deletingLastPathComponent().path]
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, app.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installation
        }
        do {
            try relaunch.run()
        } catch {
            if renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, app.path, UInt32(RENAME_SWAP)) != 0 {
                // Keep the old app if rollback could not complete.
                NSWorkspace.shared.activateFileViewerSelecting([staged])
                return
            }
            throw error
        }
    }
}

struct UpdateSettings: View {
    @Bindable var updates: AppUpdates
    let canInstall: () -> Bool
    @State private var token = ""

    var body: some View {
        Section("App and dependency updates") {
            if updates.hasToken {
                Toggle("Install updates automatically on launch", isOn: $updates.automatic)
                    .help("Install a signed release when the app is idle, then reopen Media Harbor")
                Button("Remove GitHub Token", role: .destructive) { updates.removeToken() }
                    .disabled(updates.working)
            } else {
                SecureField("GitHub repository token", text: $token)
                Button("Save GitHub Token") {
                    updates.saveToken(token)
                    token = ""
                }
                .disabled(token.isEmpty || updates.working)
                Link("Create a fine-grained GitHub token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                Text("Grant Contents read access to TMRJIJ/MediaHarbor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check for Updates") { Task { await updates.check() } }
                    .disabled(updates.working || !updates.hasToken)
                if updates.available != nil {
                    Button("Install and Restart") { Task { await updates.install(canInstall: canInstall) } }
                        .disabled(updates.working || !canInstall())
                }
                Link("GitHub Releases", destination: AppUpdates.releasesPage)
            }
            if !updates.message.isEmpty {
                Text(updates.message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Bundled dependencies are updated together with the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
