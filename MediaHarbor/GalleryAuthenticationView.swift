import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GallerySiteDetail: View {
    let site: GallerySite
    let open: (URL) -> Void
    let createRule: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            PageHeading(title: site.name, detail: site.hosts.isEmpty ? "Enter a supported URL for this site." : site.hosts.joined(separator: ", "))
            if !site.examples.isEmpty {
                Text("Supported URL examples").font(.headline)
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        ForEach(site.examples.keys.sorted(), id: \.self) { key in
                            GridRow {
                                Text(key.capitalized).foregroundStyle(.secondary)
                                Text(site.examples[key] ?? "")
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 215)
            }
            TextField("Paste a \(site.name) URL", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .onChange(of: address) { error = nil }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Create Web Rule…", action: makeRule)
                    .help("Use a supported hostname to start an editable browser rule")
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                Button("Open and Scan", action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 630)
    }

    private func submit() {
        guard let url = URL.web(address, assumingHTTPS: true) else {
            error = "Enter a valid website URL."
            return
        }
        dismiss()
        open(url)
    }

    private func makeRule() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let example = site.examples["video"] ?? site.examples["post"] ?? site.examples["thread"]
            ?? site.examples["tweet"] ?? site.examples["image"]
            ?? site.examples.sorted { $0.key < $1.key }.first?.value
        let source = input.isEmpty ? (example ?? site.hosts.first) : input
        guard let source, let host = URL.web(source, assumingHTTPS: true)?.host?.lowercased() else {
            error = "Enter a supported website URL for this rule."
            return
        }
        let matchingHost = site.hosts.filter { host == $0 || host.hasSuffix("." + $0) }
            .max { $0.count < $1.count }
        guard matchingHost != nil || site.hosts.isEmpty else {
            error = "Use a URL from one of this template’s supported domains."
            return
        }
        createRule(matchingHost ?? host)
        dismiss()
    }
}

struct GalleryAuthenticationView: View {
    let gallery: GalleryIntegration
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var provider = "pixiv"
    @State private var instance = ""
    @State private var client = ""
    @State private var secret = ""
    @State private var callback = ""
    @State private var accountToDisconnect: String?

    private var account: String {
        GalleryIntegration.account(provider, instance: instance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(title: "Site authentication", detail: "Use browser cookies for gallery-dl and yt-dlp, or connect a gallery-dl account.")
                .padding(.horizontal, 22)
                .padding(.top, 20)

            Form {
                Section("Browser cookies") {
                    Text("Sign in through Site Browser to share the matching cookies automatically. You can also import a Netscape cookies.txt file for this app session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Import cookies.txt…") { importing = true }
                            .help("Use a Netscape-format cookie file for the current app session")
                        Button("Clear Imported Cookies") { gallery.clearImportedCookies() }
                            .help("Remove cookies imported from a file")
                            .disabled(gallery.importedCookieCount == 0)
                    }
                    if !gallery.cookieMessage.isEmpty {
                        Text(gallery.cookieMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("OAuth accounts") {
                    Picker("Provider", selection: $provider) {
                        ForEach(gallery.sites.filter(\.oauth)) { site in Text(site.name).tag(site.id) }
                    }
                    .disabled(gallery.authorizing)
                    .onChange(of: provider) {
                        client = ""
                        secret = ""
                        callback = ""
                        gallery.resetAuthorizationMessage()
                    }
                    if provider == "mastodon" {
                        TextField("Instance hostname", text: $instance, prompt: Text("mastodon.social"))
                            .disabled(gallery.authorizing)
                    } else if !gallery.authorizing {
                        DisclosureGroup(provider == "flickr" ? "Required Flickr API credentials" : "Custom app credentials") {
                            TextField("Client ID or API key", text: $client)
                            SecureField("Client secret", text: $secret)
                        }
                    }
                    if gallery.authorizing {
                        if let url = gallery.authorizationURL {
                            Button("Reopen Authorization Page") { NSWorkspace.shared.open(url) }
                            HStack {
                                SecureField(gallery.waitingForCode ? "Authorization code" : "Callback URL", text: $callback)
                                    .onSubmit(submitCallback)
                                Button("Continue", action: submitCallback)
                                    .disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        Button("Cancel Authorization", role: .cancel) { gallery.cancelAuthorization() }
                    } else {
                        HStack {
                            Button(gallery.accounts.contains(account) ? "Reconnect Account…" : "Connect Account…") {
                                gallery.authorize(provider, instance: instance, client: client, secret: secret)
                                secret = ""
                            }
                            if gallery.accounts.contains(account) {
                                Button("Disconnect…", role: .destructive) { accountToDisconnect = account }
                            }
                        }
                    }
                    if !gallery.authMessage.isEmpty {
                        Text(gallery.authMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    if !gallery.accounts.isEmpty {
                        Text("Connected: " + gallery.accounts.sorted().joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !gallery.version.isEmpty {
                    Text("gallery-dl \(gallery.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(width: 620, height: 530)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            if let url = try? result.get() { gallery.importCookies(from: url) }
        }
        .alert("Disconnect this account?", isPresented: Binding(
            get: { accountToDisconnect != nil },
            set: { if !$0 { accountToDisconnect = nil } }
        )) {
            Button("Cancel", role: .cancel) { accountToDisconnect = nil }
            Button("Disconnect", role: .destructive) {
                if let accountToDisconnect { gallery.disconnect(accountToDisconnect) }
                accountToDisconnect = nil
            }
        } message: {
            Text("Media Harbor will remove its saved authorization from Keychain.")
        }
        .onDisappear { gallery.cancelAuthorization() }
    }

    private func submitCallback() {
        gallery.submitAuthorizationCode(callback)
        callback = ""
    }
}
