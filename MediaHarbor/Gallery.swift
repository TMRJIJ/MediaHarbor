import AppKit
import ImageIO
import SwiftUI

struct GalleryView: View {
    let transfers: Transfers
    @State private var viewer: ViewerSelection?

    private var photos: [Transfer] {
        transfers.galleryImages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                PageHeading(title: "Image gallery", detail: "Preview downloaded images or play them as a slideshow.")
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
            if photos.isEmpty {
                ContentUnavailableView("No downloaded images", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Images will appear here when they finish downloading."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            Button {
                                viewer = ViewerSelection(photos: photos, index: index)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    if let url = photo.output {
                                        LocalImage(url: url, pixels: 380)
                                            .frame(height: 112)
                                            .frame(maxWidth: .infinity)
                                            .background(.quaternary.opacity(0.45))
                                            .clipShape(.rect(cornerRadius: 10))
                                    }
                                    Text(photo.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(photo.name)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.top, 19)
        .sheet(item: $viewer) { selection in ImageViewer(selection: selection) }
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

private struct LocalImage: View {
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
