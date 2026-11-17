#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Tonewell: what the same app needs on a Mac (main session, 2026-11-17: the Mac app without Lightroom).

/// Mouse wheel and trackpad scrolling over the picture (after the plug-in app's ScrollCatcher, app/Sources/LRCDF/Compare.swift):
/// a wheel zooms about the pointer; two fingers on a trackpad move a zoomed picture. Pinching stays with SwiftUI's
/// MagnifyGesture, as on the iPad.
struct ScrollCatcher: NSViewRepresentable {
    /// (wheel steps, scrolled by, where: 0…1 across the view from the top left)
    let handler: (CGFloat, CGSize, CGPoint) -> Void
    func makeNSView(context: Context) -> Catcher { Catcher(handler: handler) }
    func updateNSView(_ view: Catcher, context: Context) { view.handler = handler }

    final class Catcher: NSView {
        var handler: (CGFloat, CGSize, CGPoint) -> Void
        private var monitor: Any?
        init(handler: @escaping (CGFloat, CGSize, CGPoint) -> Void) { self.handler = handler; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.width > 1 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let place = CGPoint(x: point.x / self.bounds.width, y: 1 - point.y / self.bounds.height)
                if event.hasPreciseScrollingDeltas {
                    guard event.momentumPhase == [] else { return nil }        // coasting after the fingers left does not count
                    self.handler(0, CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), place)
                } else {
                    self.handler(event.scrollingDeltaY, .zero, place)
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

enum MacFiles {
    static let kinds: [UTType] = [.rawImage, .image]
    /// Photos inside dropped items: files as they are, folders searched one level and below (pictures only).
    static func photos(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue {
                let items = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
                while let f = items?.nextObject() as? URL { if isPhoto(f) { out.append(f) } }
            } else if isPhoto(u) { out.append(u) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    static func isPhoto(_ u: URL) -> Bool {
        guard let t = (try? u.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return kinds.contains { t.conforms(to: $0) }
    }
    /// Where to save: a folder chosen in the system's panel, opened at the photos' own folder (the panel also gives the
    /// sandboxed app the right to write there). nil = cancelled.
    @MainActor static func chooseFolder(near photos: [Photo]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "存到这里"
        panel.message = "选一个文件夹存放修好的照片（默认打开的是原片所在的文件夹）。同名的文件不会被覆盖。"
        panel.directoryURL = photos.compactMap { $0.source?.deletingLastPathComponent() }.first
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The save sheet: file type, then where (the system's folder panel).
struct SaveSheet: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @AppStorage("studio.format") private var format = Engine.Format.jpeg.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("存储修好的照片").font(DS.section)
            Picker("格式", selection: $format) {
                Text("JPEG").tag(Engine.Format.jpeg.rawValue)
                Text("HEIC").tag(Engine.Format.heic.rawValue)
                Text("TIFF").tag(Engine.Format.tiff.rawValue)
            }
            .pickerStyle(.segmented)
            Text(format == "jpeg" ? "JPEG：8 位，哪里都能打开，适合直接交付。" : format == "heic" ? "HEIC：10 位广色域，文件小，苹果设备和新系统都能打开。" : "TIFF：16 位广色域，文件大，适合还要继续精修。")
                .font(DS.note).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(studio.photos.count > 1 ? "选择位置并存储 \(studio.photos.count) 张…" : "选择位置并存储…") {
                    dismiss()
                    let photos = studio.photos, f = Engine.Format(rawValue: format) ?? .jpeg
                    DispatchQueue.main.async {
                        if let folder = MacFiles.chooseFolder(near: photos) { studio.exportAll(to: folder, format: f) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
        .preferredColorScheme(.dark)
    }
}

/// What the menus ask the window for (⌘O, ⌘S).
final class MacRequests: ObservableObject {
    static let shared = MacRequests()
    @Published var open = false
    @Published var save = false
}

/// The menu bar: 打开… ⌘O, 存储… ⌘S, 撤销 ⌘Z / 重做 ⇧⌘Z (the look and its settings).
struct StudioCommands: Commands {
    @ObservedObject var studio: Studio
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开照片…") { MacRequests.shared.open = true }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("存储修好的照片…") { MacRequests.shared.save = true }.keyboardShortcut("s").disabled(studio.photos.isEmpty || studio.busy)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { studio.undo() }.keyboardShortcut("z").disabled(!studio.canUndo)
            Button("重做") { studio.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!studio.canRedo)
        }
    }
}
#endif
