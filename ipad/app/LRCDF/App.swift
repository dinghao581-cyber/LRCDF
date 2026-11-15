import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct LRCDFPadApp: App {
    @StateObject private var studio = Studio()
    init() {
        ModelStore.installIfReady()     // new models downloaded last time go in place now, before any is loaded
        // test hook: 一键修图 --selftest <photo> <outdir>  → every look at full size as HEIC, timings on stdout
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "--selftest"), a.count > i + 2 { SelfTest.run(URL(fileURLWithPath: a[i + 1]), URL(fileURLWithPath: a[i + 2])); exit(0) }
        // test hook: --beauty <outdir> [--full] <photo>…  → every beauty level at preview size (and one full export)
        if let i = a.firstIndex(of: "--beauty"), a.count > i + 2 {
            let rest = Array(a[(i + 2)...]); let full = rest.contains("--full")
            SelfTest.beauty(rest.filter { $0 != "--full" }.map { URL(fileURLWithPath: $0) }, URL(fileURLWithPath: a[i + 1]), full: full); exit(0)
        }
        // test hook: --snapshot <outdir> <photo>…  → the editor drawn at iPad sizes as PNG
        if let i = a.firstIndex(of: "--snapshot"), a.count > i + 2 {
            let out = URL(fileURLWithPath: a[i + 1]); let files = a[(i + 2)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in await SelfTest.snapshot(files, out); exit(0) }
        }
        // test hook: --update-check  → one check (DEBUG: LRCDF_UPDATE_URL / LRCDF_UPDATE_KEY point it at a test server),
        // then the model download if it is small enough (or --download), result on stdout
        if a.contains("--update-check") {
            Task { @MainActor in
                let n = UpdateNotice.shared
                print("app", UpdateNotice.appVersion, "models", ModelStore.installedVersion, "installed now:", ModelStore.justInstalled ?? "-", "enabled:", n.enabled)
                await n.check()
                if case .offer = n.models, a.contains("--download") { await n.download() }
                print("newer:", n.newer.map { "\($0.version) \($0.note ?? "") unknownFormat=\($0.unknownFormat)" } ?? "none")
                print("models:", n.models)
                print("model source:", ModelStore.url("Critic")?.path.contains("Application Support") == true ? "update" : "app")
                exit(0)
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(studio).preferredColorScheme(.dark)
                .onAppear {   // test hook: --open <file>… imports those files at start
                    let a = ProcessInfo.processInfo.arguments
                    if let i = a.firstIndex(of: "--open") { studio.add(a[(i + 1)...].map { URL(fileURLWithPath: $0) }) }
                    UpdateNotice.shared.start()
                }
        }
    }
}

enum Palette {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let line = Color.white.opacity(0.12)
    static let soft = Color.white.opacity(0.6)
    static let glow = Color(red: 0.96, green: 0.80, blue: 0.62)
}

/// A file handed over by the photo picker, copied into the app's folder (RAW stays RAW).
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let dest = Studio.folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var studio: Studio
    @State private var picks: [PhotosPickerItem] = []
    @State private var showFiles = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            if studio.photos.isEmpty { welcome } else { EditorView(picks: $picks, showFiles: $showFiles) }
        }
        .onChange(of: picks) { _, items in load(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.rawImage, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            studio.add(urls.compactMap(copyIn))
        }
        .alert(studio.message ?? "", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) {
            Button("好") { studio.message = nil }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "wand.and.stars").font(.system(size: 54)).foregroundStyle(Palette.glow)
            Text("一键修图").font(.system(size: 34, weight: .semibold))
            Text("选几张照片，挑一个风格，存回相册。RAW 也可以。").foregroundStyle(Palette.soft)
            HStack(spacing: 14) {
                PhotosPicker(selection: $picks, matching: .images, preferredItemEncoding: .current) {
                    Label("从相册选", systemImage: "photo.on.rectangle").bigButton(primary: true)
                }
                Button { showFiles = true } label: { Label("从文件选", systemImage: "folder").bigButton(primary: false) }
                    .buttonStyle(.plain)
            }
            if case .working(let s) = studio.stage { ProgressView(s).padding(.top, 8) }
        }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picks = []
        Task {
            var urls: [URL] = []
            for item in items {
                if let f = try? await item.loadTransferable(type: PickedFile.self) { urls.append(f.url) }
            }
            if urls.isEmpty { studio.message = "没能读到选中的照片。" }
            studio.add(urls)
        }
    }

    /// Files from the Files app are security-scoped: copy them in while access is granted.
    private func copyIn(_ url: URL) -> URL? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dest = Studio.folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + url.lastPathComponent)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }
}

extension View {
    func bigButton(primary: Bool) -> some View {
        self.font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 22).padding(.vertical, 13)
            .background(Capsule().fill(primary ? Palette.glow : Color.white.opacity(0.08)))
            .foregroundStyle(primary ? Color.black : Color.white)
    }
}
