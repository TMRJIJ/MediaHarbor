import AppKit
import AVKit
import ImageIO
import SwiftUI

struct GalleryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", images = "Images", videos = "Videos"
        var id: Self { self }

        func includes(_ media: Transfer) -> Bool {
            self == .all || (self == .images ? media.kind == .image : media.kind == .video)
        }
    }

    private enum TrashTarget {
        case file(URL), project(URL)

        var title: String {
            switch self {
            case .file: "Move this file to Trash?"
            case .project: "Move this project’s saved files to Trash?"
            }
        }
    }

    let transfers: Transfers
    @State private var filter = Filter.all
    @State private var viewer: ViewerSelection?
    @State private var video: Transfer?
    @State private var missingFiles: Set<URL>?
    @State private var pendingTrash: TrashTarget?
    @State private var trashError: String?

    var body: some View {
        let items = transfers.galleryMedia.filter {
            filter.includes($0) && $0.output.map { missingFiles?.contains($0) == false } == true
        }
        let photos = items.filter { $0.kind == .image }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                PageHeading(title: "Media gallery", detail: "Browse downloaded images and play saved videos.")
                Button {
                    viewer = ViewerSelection(photos: photos, index: 0, playing: true)
                } label: {
                    Label("Slideshow", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help("Play downloaded images in order")
                .disabled(photos.isEmpty)
            }
            .padding(.horizontal, 26)
            Picker("Show media", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.horizontal, 26)
            if let trashError {
                Label(trashError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(.horizontal, 26)
            }
            if missingFiles == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("No downloaded media", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Saved images and videos appear here after download."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                        ForEach(items) { item in
                            if let url = item.output {
                                card(item, at: url) {
                                    if item.kind == .video {
                                        video = item
                                    } else if let index = photos.firstIndex(where: { $0.id == item.id }) {
                                        viewer = ViewerSelection(photos: photos, index: index)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.top, 19)
        .task {
            while !Task.isCancelled {
                let urls = transfers.galleryMedia.compactMap(\.output)
                let missing = await Task.detached(priority: .utility) {
                    Set(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
                }.value
                guard !Task.isCancelled else { return }
                if missingFiles != missing { missingFiles = missing }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $viewer) { selection in ImageViewer(selection: selection) }
        .sheet(item: $video) { item in
            if let url = item.output { VideoViewer(url: url, name: item.name) }
        }
        .alert(pendingTrash?.title ?? "", isPresented: Binding(get: { pendingTrash != nil }, set: {
            if !$0 { pendingTrash = nil }
        }), presenting: pendingTrash) { target in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                switch target {
                case .file(let url): trashError = transfers.trashSavedFile(url)
                case .project(let source): trashError = transfers.trashProject(source)
                }
            }
        } message: { target in
            switch target {
            case .file(let url): Text(url.lastPathComponent)
            case .project: Text("This also removes the project from the download queue.")
            }
        }
    }

    private func card(_ item: Transfer, at url: URL, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                Group {
                    if item.kind == .video {
                        VideoThumbnail(url: url)
                    } else {
                        LocalImage(url: url, pixels: 380)
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.45))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(item.kind == .video ? "Play \(item.name)" : "Preview \(item.name)")
            .accessibilityLabel(item.kind == .video ? "Play \(item.name)" : "Preview \(item.name)")
            HStack {
                Text(item.name).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Move to Trash…", role: .destructive) { pendingTrash = .file(url) }
                    Button("Move Project to Trash…", role: .destructive) { pendingTrash = .project(item.media.projectSource) }
                        .disabled(!transfers.canTrashProject(item.media.projectSource))
                } label: {
                    Label("File Actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

private struct VideoThumbnail: View {
    let url: URL
    @State private var bitmap: CGImage?

    var body: some View {
        ZStack {
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 27))
                .foregroundStyle(bitmap == nil ? Color.accentColor : .white)
                .shadow(radius: 3)
        }
        .task(id: url) {
            bitmap = nil
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 380, height: 220)
            let frame = try? await generator.image(at: .zero)
            if !Task.isCancelled { bitmap = frame?.image }
        }
    }
}

private struct VideoViewer: View {
    let url: URL
    let name: String
    @State private var player: AVPlayer?
    @State private var unavailable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if unavailable {
                    ContentUnavailableView("Video playback unavailable", systemImage: "film",
                                           description: Text("Try opening this file in your default video player."))
                } else if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Button("Open in Default Player") { NSWorkspace.shared.open(url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 770, height: 560)
        .task {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) == true
            guard !Task.isCancelled else { return }
            guard playable else { unavailable = true; return }
            let playback = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = playback
            playback.play()
        }
        .onDisappear { player?.pause() }
    }
}

private struct ViewerSelection: Identifiable {
    let id = UUID()
    let photos: [Transfer]
    var index: Int
    var playing = false
}

private struct ImageViewer: View {
    @State var selection: ViewerSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let photo = selection.photos[selection.index]
        VStack(spacing: 12) {
            if let url = photo.output {
                LocalImage(url: url, pixels: 2200)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.40), in: .rect(cornerRadius: 14))
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(selection.index + 1) of \(selection.photos.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous image")
                    .accessibilityLabel("Previous image")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { selection.playing.toggle() } label: {
                    Image(systemName: selection.playing ? "pause.fill" : "play.fill")
                }
                .help(selection.playing ? "Pause slideshow" : "Play slideshow")
                .accessibilityLabel(selection.playing ? "Pause slideshow" : "Play slideshow")
                .disabled(selection.photos.count < 2)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next image")
                    .accessibilityLabel("Next image")
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 770, height: 560)
        .task(id: selection.playing) {
            guard selection.playing, selection.photos.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                move(1)
            }
        }
    }

    private func move(_ offset: Int) {
        selection.index = (selection.index + offset + selection.photos.count) % selection.photos.count
    }
}

struct LocalImage: View {
    let url: URL
    let pixels: Int
    @State private var bitmap: CGImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
            } else if finished {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    .help("Image unavailable")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            bitmap = nil
            finished = false
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels
                ] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            }.value
            guard !Task.isCancelled else { return }
            bitmap = image
            finished = true
        }
    }
}
