import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

/// Drives the standalone remover window: pick/drop an image, run the cutout off
/// the main actor, then copy/save the result. Vision by default; the opt-in HD
/// model when it's active.
@MainActor
@Observable
final class BackgroundRemoverModel {
    enum State: Equatable {
        case empty
        case working
        case done
        case failed(String)
    }

    private(set) var state: State = .empty
    private(set) var cutout: NSImage?
    /// True when the HD model produced this result (drives the quality badge).
    private(set) var usedHD = false

    private var cutoutData: Data?
    private var savedURL: URL?

    /// NSOpenPanel → any image file.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to remove its background"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            state = .failed("Couldn't read that image.")
            return
        }
        process(data)
    }

    private func process(_ data: Data) {
        state = .working
        cutout = nil; cutoutData = nil; savedURL = nil
        let hd = HDBackgroundModelManager.shared.activeModel
        usedHD = hd != nil
        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) {
                BackgroundRemovalService.cutout(imageData: data, using: hd)
            }.value
            guard let self else { return }
            if let out, let image = NSImage(data: out) {
                self.cutoutData = out
                self.cutout = image
                self.state = .done
                SoundEffects.play(.done)
            } else {
                self.state = .failed("No subject found in that image.")
            }
        }
    }

    /// Copy the cutout: a temp file URL (so a paste into Finder/terminals lands
    /// the PNG) plus the bitmap for image editors — same shape as a screenshot copy.
    func copy() {
        guard let data = cutoutData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pear cutout \(UUID().uuidString.prefix(6)).png")
        try? data.write(to: url)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setData(data, forType: .png)
        SoundEffects.play(.copy)
    }

    func save() {
        guard let data = cutoutData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "cutout.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            savedURL = url
        }
    }

    var isSaved: Bool { savedURL != nil }
    func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    func reset() {
        state = .empty; cutout = nil; cutoutData = nil; savedURL = nil
    }
}

struct BackgroundRemoverView: View {
    let model: BackgroundRemoverModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: handleDrop)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
                .padding(6)
                .animation(.easeOut(duration: 0.12), value: targeted)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .empty, .failed:
            dropArea
        case .working:
            working
        case .done:
            result
        }
    }

    private var dropArea: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.and.background.dotted")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an image here")
                .font(Theme.emphasis)
            Text("or")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Button("Choose Image…") { model.choose() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            if case .failed(let message) = model.state {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
            }
            Spacer()
            qualityFootnote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
    }

    private var working: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Removing background…")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text(model.usedHD ? "High quality" : "Fast")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var result: some View {
        VStack(spacing: 12) {
            ZStack {
                Checkerboard()
                if let cutout = model.cutout {
                    Image(nsImage: cutout)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                Text(model.usedHD ? "High quality" : "Fast")
                    .font(Theme.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }

            HStack(spacing: 8) {
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { model.save() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                if model.isSaved {
                    Button { model.reveal() } label: { Label("Reveal", systemImage: "folder") }
                }
                Spacer()
                Button { model.reset() } label: { Label("New Image", systemImage: "photo.badge.plus") }
            }
            .font(Theme.body)
            qualityFootnote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var qualityFootnote: some View {
        if !Prefs.hdBackgroundRemoval {
            Text("Using the fast built-in cutout. Turn on High-quality mode in Settings for sharper edges (hair, fine detail).")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in model.load(url) }
        }
        return true
    }
}

/// A light/dark checker so the cutout's transparency reads clearly.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let dark = (row + col) % 2 == 0
                    context.fill(
                        Path(CGRect(x: x, y: y, width: tile, height: tile)),
                        with: .color(dark ? Color(white: 0.20) : Color(white: 0.27)))
                    x += tile; col += 1
                }
                y += tile; row += 1
            }
        }
    }
}
