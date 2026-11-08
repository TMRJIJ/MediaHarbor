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
    @State private var selectedProject: URL?
    @State private var viewer: ViewerSelection?
    @State private var video: Transfer?
    @State private var missingFiles: Set<URL>?
    @State private var pendingTrash: TrashTarget?
    @State private var trashError: String?

    var body: some View {
        let available = transfers.galleryMedia.filter {
            $0.output.map { missingFiles?.contains($0) == false } == true
        }
        let names = transfers.projectNamesForQueue()
        let grouped = Dictionary(grouping: available, by: \.media.projectSource)
        var seen: Set<URL> = []
        let projects = available.compactMap { item -> GalleryProject? in
            let source = item.media.projectSource
            guard seen.insert(source).inserted, let items = grouped[source] else { return nil }
            return GalleryProject(id: source, name: names[source] ?? item.projectName ?? transfers.folderRule.projectName(for: item.media), items: items)
        }
        let project = projects.first { $0.id == selectedProject }

        VStack(alignment: .leading, spacing: 16) {
            if let trashError {
                Label(trashError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(.horizontal, 26)
            }
            if let project {
                projectMedia(project)
            } else {
                PageHeading(title: "Gallery Projects", detail: "Move across a project’s thumbnail to preview its images.")
                    .padding(.horizontal, 26)
                if missingFiles == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if projects.isEmpty {
                    ContentUnavailableView("No downloaded media", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Saved images and videos appear here after download."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], spacing: 22) {
                            ForEach(projects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 20)
                    }
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

    private func projectCard(_ project: GalleryProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                filter = .all
                selectedProject = project.id
            } label: {
                ProjectThumbnail(previews: project.previews)
                    .frame(height: 132)
                    .background(.quaternary.opacity(0.45))
                    .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(project.name), \(project.items.count.formatted()) files")
            .help("Open project")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(project.items.count.formatted()) saved files").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Move Project to Trash…", role: .destructive) { pendingTrash = .project(project.id) }
                        .disabled(!transfers.canTrashProject(project.id))
                } label: {
                    Label("Project Actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func projectMedia(_ project: GalleryProject) -> some View {
        let items = project.items.filter(filter.includes)
        let photos = items.filter { $0.kind == .image }
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                selectedProject = nil
            } label: {
                Label("All Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 26)
            HStack(alignment: .bottom) {
                PageHeading(title: project.name, detail: "Browse saved images and videos in this project.")
                Button {
                    viewer = ViewerSelection(photos: photos, index: 0, playing: true)
                } label: {
                    Label("Slideshow", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help("Play this project’s images in order")
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
            if items.isEmpty {
                ContentUnavailableView("No \(filter.rawValue.lowercased()) in this project", systemImage: "photo.on.rectangle.angled")
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

private struct GalleryProject: Identifiable {
    let id: URL
    let name: String
    let items: [Transfer]

    var previews: [Transfer] {
        let images = items.filter { $0.kind == .image }
        let candidates = images.isEmpty ? items : images
        let count = min(candidates.count, 12)
        guard count > 1 else { return candidates }
        return (0..<count).map { candidates[$0 * (candidates.count - 1) / (count - 1)] }
    }
}

private struct ProjectThumbnail: View {
    let previews: [Transfer]
    @State private var index = 0

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let item = previews.indices.contains(index) ? previews[index] : previews.first,
                   let url = item.output {
                    if item.kind == .video {
                        VideoThumbnail(url: url)
                    } else {
                        LocalImage(url: url, pixels: 560, fill: true)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where proxy.size.width > 0 && !previews.isEmpty:
                    let fraction = min(1, max(0, point.x / proxy.size.width))
                    index = min(previews.count - 1, Int(fraction * CGFloat(previews.count)))
                case .ended:
                    index = 0
                default:
                    break
                }
            }
        }
        .accessibilityHidden(true)
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
    var fill = false
    @State private var bitmap: CGImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
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
