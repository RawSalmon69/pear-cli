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
    /// Why the last Save didn't write, shown under the actions.
    private(set) var saveError: String?

    private(set) var cutoutData: Data?
    private var savedURL: URL?

    /// The image → cutout step. Live: the HD model when it's on and ready, else
    /// Vision, off the main actor. Tests stand in their own.
    typealias Engine = @MainActor (Data) async -> BackgroundRemovalService.Cutout?
    private let engine: Engine
    /// The cutout in flight. Only the newest load may write results: a slower
    /// earlier image must not replace a later drop's (or play its sound).
    private(set) var job: Task<Void, Never>?
    private var generation = 0

    init(engine: @escaping Engine = BackgroundRemoverModel.live) {
        self.engine = engine
    }

    static func live(_ data: Data) async -> BackgroundRemovalService.Cutout? {
        let hd = await HDBackgroundModelManager.shared.prepared()
        return await Task.detached(priority: .userInitiated) {
            BackgroundRemovalService.cutoutReportingEngine(imageData: data, using: hd)
        }.value
    }

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
        load(try? Data(contentsOf: url))
    }

    /// Image bytes from a file, a drop or a paste; one path for all three, so
    /// each decodes the same way. Bytes that aren't an image show the error.
    func load(_ data: Data?) {
        job?.cancel()
        generation += 1
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil else {
            state = .failed("Couldn't read that image.")
            return
        }
        process(data)
    }

    /// What to read from a drop or paste offering `types`: a file URL first
    /// (Finder, whose copy also carries the file's icon), else the first image
    /// type (a browser's image bytes), else nothing (text, a web link alone).
    nonisolated static func pick(_ types: [UTType]) -> UTType? {
        types.contains(.fileURL) ? .fileURL : types.first { $0.conforms(to: .image) }
    }

    /// ⌘V: the image on `pasteboard`, through `pick`. False when there is none.
    func paste(from pasteboard: NSPasteboard) -> Bool {
        switch Self.pick((pasteboard.types ?? []).compactMap { UTType($0.rawValue) }) {
        case .fileURL?:
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
            guard let url = urls?.first else { return false }
            load(url)
        case let type?:
            load(pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)))
        case nil:
            return false
        }
        return true
    }

    private func process(_ data: Data) {
        state = .working
        cutout = nil; cutoutData = nil; savedURL = nil; saveError = nil
        let current = generation
        job = Task { [weak self] in
            guard let engine = self?.engine else { return }
            let out = await engine(data)
            guard let self, self.generation == current else { return }
            if let out, let image = NSImage(data: out.png) {
                self.cutoutData = out.png
                self.cutout = image
                self.usedHD = out.usedHD
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
        guard cutoutData != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "cutout.png"
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    /// Writes the cutout; Reveal is offered only for a file that was written.
    func save(to url: URL) {
        guard let data = cutoutData else { return }
        do {
            try data.write(to: url)
            savedURL = url
            saveError = nil
        } catch {
            savedURL = nil
            saveError = "Couldn't save the cutout: \(error.localizedDescription)"
        }
    }

    var isSaved: Bool { savedURL != nil }
    func reveal() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    func reset() {
        job?.cancel()
        generation += 1 // a cutout still in flight must not land after this
        state = .empty; cutout = nil; cutoutData = nil; savedURL = nil; saveError = nil
    }
}

struct BackgroundRemoverView: View {
    let model: BackgroundRemoverModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: Theme.Space.medium) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.large)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted, perform: handleDrop)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
                .padding(Theme.Space.small)
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
        VStack(spacing: Theme.Space.medium) {
            Spacer()
            Image(systemName: "person.and.background.dotted")
                // Exception: an empty-state illustration, not text.
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an image here")
                .font(Theme.Typography.large(.medium))
            Text("or")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
            Button("Choose Image…") { model.choose() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            if case .failed(let message) = model.state {
                Text(message)
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(Theme.warn)
            }
            Spacer()
            qualityFootnote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
    }

    private var working: some View {
        VStack(spacing: Theme.Space.medium) {
            Spacer()
            ProgressView()
            Text("Removing background…")
                .font(Theme.Typography.body())
                .foregroundStyle(.secondary)
            // What is being tried; the result's badge says what actually ran.
            Text(Prefs.hdBackgroundRemoval && HDBackgroundModelManager.shared.isDownloaded ? "High quality" : "Fast")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var result: some View {
        VStack(spacing: Theme.Space.medium) {
            ZStack {
                Checkerboard()
                if let cutout = model.cutout {
                    Image(nsImage: cutout)
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.Space.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(alignment: .topLeading) {
                Text(model.usedHD ? "High quality" : "Fast")
                    .font(Theme.Typography.small(.semibold))
                    .padding(.horizontal, Theme.Space.small).padding(.vertical, Theme.Space.xSmall)
                    .glassCard()
                    .padding(Theme.Space.small)
            }

            HStack(spacing: Theme.Space.small) {
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { model.save() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                if model.isSaved {
                    Button { model.reveal() } label: { Label("Reveal", systemImage: "folder") }
                }
                Spacer()
                Button { model.reset() } label: { Label("New Image", systemImage: "photo.badge.plus") }
            }
            .font(Theme.Typography.body())
            if let error = model.saveError {
                Text(error)
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(Theme.warn)
            }
            qualityFootnote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var qualityFootnote: some View {
        if !Prefs.hdBackgroundRemoval {
            Text("Using the built-in cutout. High-quality mode in Settings handles hair and fine edges better.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A Finder file or a browser's image bytes, chosen by `pick`; anything
    /// else is refused, so the drop is never accepted and then ignored.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            switch BackgroundRemoverModel.pick(provider.registeredContentTypes) {
            case .fileURL?:
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    let data = url.flatMap { $0.isFileURL ? try? Data(contentsOf: $0) : nil }
                    Task { @MainActor in model.load(data) }
                }
            case let type?:
                _ = provider.loadDataRepresentation(for: type) { data, _ in
                    Task { @MainActor in model.load(data) }
                }
            case nil:
                continue
            }
            return true
        }
        return false
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
