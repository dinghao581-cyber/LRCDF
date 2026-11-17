import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct LRCDFPadApp: App {
    #if TESTHOOKS
    nonisolated(unsafe) static var keep: AnyObject?
    #endif
    @StateObject private var studio = Studio()
    @ObservedObject private var fonts = Fonts.shared
    init() {
        ModelStore.installIfReady()     // new models downloaded last time go in place now, before any is loaded
        // Test hooks (launch arguments): compiled only into test builds (TESTHOOKS: Debug, or install_device.sh --test);
        // the published .ipa and normal installs have none of them (main session, 2026-11-16).
        #if TESTHOOKS
        // test hook: <app> --selftest <photo> <outdir>  → every look at full size as HEIC, timings on stdout
        let a = ProcessInfo.processInfo.arguments
        // Offline engine measurements; only present in TESTHOOKS builds.
        if let i = a.firstIndex(of: "--denoise"), a.count > i + 2 {
            let out = file(a[i + 1]), files = a[(i + 2)...].map(file)
            let t = Thread { let ok = SelfTest.denoise(files, out); exit(ok ? 0 : 1) }
            t.stackSize = 64 << 20; t.start()
            #if os(macOS)
            // Keep this measurement process headless. Closing a test window
            // must not end a partially written batch with a successful exit.
            dispatchMain()
            #endif
        }
        // test hook: --tweaks <outdir> <photo>  → the photo with each tweak at both ends
        if let i = a.firstIndex(of: "--tweaks"), a.count > i + 2 {
            let t = Thread { SelfTest.tweaks(file(a[i + 2]), file(a[i + 1])); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --shape <outdir> <photo>…  → each photo with each 塑形 switch on its own, and all together
        if let i = a.firstIndex(of: "--shape"), a.count > i + 2 {
            let out = file(a[i + 1]), files = a[(i + 2)...].map(file)
            let t = Thread { SelfTest.shape(files, out); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --skinlab <outdir> [--only beauty] <photo>…  → each photo neutral / tone only / LUT look only / retouching
        // only / even light only / the app's default, and its skin mask (research: skin colour per skin tone)
        if let i = a.firstIndex(of: "--skinlab"), a.count > i + 2 {
            let out = file(a[i + 1]); let rest = Array(a[(i + 2)...]); let only = rest.contains("--only")
            let files = rest.filter { $0 != "--only" && $0 != "beauty" }.map(file)
            let t = Thread { SelfTest.skinlab(files, out, beautyOnly: only); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --skinonly <outdir> <photo>…  → 橙黄只落皮肤 before / after per look (SelfTest.skinonly)
        if let i = a.firstIndex(of: "--skinonly"), a.count > i + 2 {
            let out = file(a[i + 1]), files = a[(i + 2)...].map(file)
            let t = Thread { SelfTest.skinonly(files, out); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --ftp  → the 联机拍摄 receiver alone (LRCDF_FTP_PASS sets the password), prints what arrives
        if a.contains("--ftp") {
            Task { @MainActor in
                let s = FTPServer(user: "lrcdf", password: ProcessInfo.processInfo.environment["LRCDF_FTP_PASS"] ?? "test")
                s.onState = { print("ftp:", $0) }
                s.onFile = { url in
                    let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
                    print("ftp received:", url.lastPathComponent, n)
                }
                s.start()
                print("ftp root:", s.root.path, "addresses:", FTPServer.addresses().map { "\($0.0)=\($0.1)" })
                Self.keep = s
            }
        }
        if a.contains("--show-tutorial") { UserDefaults.standard.set(false, forKey: "onboarded") }     // test hook
        // test paths: absolute, or relative to the app's own temporary folder (on the iPad: copied in with devicectl)
        func file(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(p) }
        // (off the main thread: on the iPad a launch that blocks for ~20 s is killed by the system watchdog)
        if let i = a.firstIndex(of: "--selftest"), a.count > i + 2 { let t = Thread { SelfTest.run(file(a[i + 1]), file(a[i + 2])); exit(0) }; t.stackSize = 64 << 20; t.start() }
        // test hook: --beauty <outdir> [--full] <photo>…  → every beauty level at preview size (and one full export)
        if let i = a.firstIndex(of: "--beauty"), a.count > i + 2 {
            let rest = Array(a[(i + 2)...]); let full = rest.contains("--full")
            let t = Thread { SelfTest.beauty(rest.filter { $0 != "--full" }.map(file), file(a[i + 1]), full: full); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --snapshot <outdir> <photo>…  → the editor drawn at iPad sizes as PNG
        if let i = a.firstIndex(of: "--snapshot"), a.count > i + 2 {
            let out = file(a[i + 1]); let files = a[(i + 2)...].map(file)
            Task { @MainActor in await SelfTest.snapshot(files, out); exit(0) }
        }
        // test hook: --denoiseexport <outdir> <photo>…  → the app's export with 降噪 off and on (SelfTest.denoiseExport)
        if let i = a.firstIndex(of: "--denoiseexport"), a.count > i + 2 {
            let out = file(a[i + 1]), files = a[(i + 2)...].map(file)
            let t = Thread { SelfTest.denoiseExport(files, out); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --profile <photo>…  → time and CPU use of each loading step (SelfTest.profile)
        if let i = a.firstIndex(of: "--profile"), a.count > i + 1 {
            let files = a[(i + 1)...].map(file)
            let t = Thread { SelfTest.profile(files); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --studioexport <outdir> <photo>…  → Tonewell's save into a folder, every format
        if let i = a.firstIndex(of: "--studioexport"), a.count > i + 2 {
            let out = file(a[i + 1]), files = a[(i + 2)...].map(file)
            Task { @MainActor in await SelfTest.studioExport(files, out); exit(0) }
        }
        // test hook: --plancheck <photo>…  → skin plans from a 512 px render against the preview-size one
        if let i = a.firstIndex(of: "--plancheck"), a.count > i + 1 {
            let files = a[(i + 1)...].map(file)
            let t = Thread { SelfTest.planCheck(files); exit(0) }; t.stackSize = 64 << 20; t.start()
        }
        // test hook: --computeplan  → where each Core ML model runs (CPU / GPU / Neural Engine)
        if a.contains("--computeplan"), #available(macOS 14.4, iOS 17.4, *) { Task { await SelfTest.computePlan(); exit(0) } }
        // test hook: --loadall <photo>…  → the background loading of a batch timed, with a photo switch and a look change during it
        if let i = a.firstIndex(of: "--loadall"), a.count > i + 1 {
            let files = a[(i + 1)...].map(file)
            Task { @MainActor in await SelfTest.loadall(files); exit(0) }
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
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(studio).preferredColorScheme(.dark)
                .id(fonts.songti)                         // the titles change face once 宋体 has arrived
                .onAppear {
                    #if TESTHOOKS
                    if ProcessInfo.processInfo.arguments.contains("--denoise") { return }
                    #endif
                    Fonts.shared.fetchIfAllowed()
                }
                .onAppear {
                    #if TESTHOOKS
                    let a = ProcessInfo.processInfo.arguments      // test hook: --open <file>… imports those files at start
                    if a.contains("--denoise") { return }
                    if let i = a.firstIndex(of: "--open") {        // relative paths: the app's temporary folder, as the other hooks
                        studio.add(a[(i + 1)...].map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent($0) })
                    }
                    #endif
                    UpdateNotice.shared.start()
                }
        }
        #if os(macOS)
        .commands { StudioCommands(studio: studio) }
        #endif
    }
}

enum Palette {      // the older names, now the design tokens (Design.swift)
    static let bg = Color.black
    static let panel = DS.smoke
    static let line = DS.line
    static let soft = DS.soft
    static let glow = DS.focus
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
        // the rights prompt, card and break reminder (Rights.swift): after the first-start tutorial, never over work going on
        .overlay { RightsHost(quiet: !onboarded || studio.busy) }
        .fullScreenCoverIfAvailable(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            Onboarding { onboarded = true }
        }
        .onChange(of: picks) { _, items in load(items) }
        .sheet(isPresented: $tethering) { TetherView().environmentObject(studio) }
        .onChange(of: phase) { _, p in Tether.shared.phase(active: p == .active) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.rawImage, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            addFiles(urls)
        }
        #if os(macOS)
        // Tonewell: photos or folders dropped on the window; ⌘O and ⌘S from the menus
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { urls.append(u) } }; group.leave() }
            }
            group.notify(queue: .main) { addFiles(MacFiles.photos(in: urls)) }
            return true
        }
        .onReceive(MacRequests.shared.$open) { if $0 { MacRequests.shared.open = false; showFiles = true } }
        .onReceive(MacRequests.shared.$save) { if $0 { MacRequests.shared.save = false; if !studio.photos.isEmpty { saving = true } } }
        .sheet(isPresented: $saving) { SaveSheet().environmentObject(studio) }
        .frame(minWidth: 900, minHeight: 620)
        #endif
        .alert(studio.message ?? "", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) {
            Button("好") { studio.message = nil }
        }
    }

    @AppStorage("onboarded") private var onboarded = false
    @State private var tethering = false
    @State private var saving = false           // Tonewell's save sheet

    /// Files picked or dropped: copied in (the originals stay as they are); Studio remembers where each came from.
    private func addFiles(_ urls: [URL]) {
        var copies: [URL] = [], sources: [URL] = []
        for u in urls { if let c = copyIn(u) { copies.append(c); sources.append(u) } }
        studio.add(copies, sources: sources)
    }
    @Environment(\.scenePhase) private var phase

    /// The first page: a greeting for the time of day and the two ways in. The tutorial comes once, on the very first
    /// start (user 2026-11-15: "第一次打开放教程", greeting "按时间问候"); 设置 can show it again.
    private var welcome: some View {
        VStack(spacing: 20) {
            Image("Logo").resizable().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Palette.glow.opacity(0.25), radius: 24)
            VStack(spacing: 8) {
                Text(Self.greeting()).font(.system(size: 34, weight: .semibold))
                Text("今天想修哪几张？").font(.system(size: 20)).foregroundStyle(Palette.soft)
            }
            HStack(spacing: 14) {
                PhotosPicker(selection: $picks, matching: .images, preferredItemEncoding: .current) {
                    Label("从相册选", systemImage: "photo.on.rectangle").bigButton(primary: true)
                }
                Button { showFiles = true } label: { Label("从文件选", systemImage: "folder").bigButton(primary: false) }
                    .buttonStyle(.plain)
                #if os(iOS)
                Button { tethering = true } label: { Label("联机拍摄", systemImage: "camera").bigButton(primary: false) }
                    .buttonStyle(.plain)
                #endif
            }
            .padding(.top, 10)
            Text("RAW 也可以 · 照片只在这台 iPad 上处理").font(.system(size: 13)).foregroundStyle(Palette.soft)
            if case .working(let s) = studio.stage { ProgressView(s).padding(.top, 8) }
        }
    }

    static func greeting(_ now: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        default: "晚上好"
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
    /// Welcome-screen buttons: the one action solid white, the other glass (Design.swift).
    @ViewBuilder func bigButton(primary: Bool) -> some View {
        if primary {
            self.font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 24).frame(height: 52).background(.white, in: Capsule())
        } else {
            self.font(.system(size: 17, weight: .medium)).foregroundStyle(DS.ink)
                .padding(.horizontal, 24).frame(height: 52).glass(Capsule(), interactive: true)
        }
    }

}

/// The tutorial: three pages, shown once (and from 设置).
struct Onboarding: View {
    let done: () -> Void
    @State private var page = 0
    private let pages: [(String, String, String)] = [
        ("photo.on.rectangle.angled", "选照片", "从相册或“文件”里选，一次可以选很多张。\nRAW 也能直接修，照片只在这台 iPad 上处理，不会上传。"),
        ("wand.and.stars", "挑一个风格", "每个风格都会按这张照片的光线自动调好。\n有人脸的照片还能选美颜：不修、自然或精致。\n左右拖动照片上的分割线，对比修之前和修之后。"),
        ("square.and.arrow.down", "存进相册", "觉得还差一点，用“微调”里的滑块调亮暗、冷暖和浓淡。\n点“存进相册”就好，原片不会被改动。"),
    ]

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                HStack { Spacer(); Button("跳过") { done() }.foregroundStyle(Palette.soft).padding(20) }
                Spacer()
                let p = pages[page]
                Image(systemName: p.0).font(.system(size: 64)).foregroundStyle(Palette.glow).frame(height: 90)
                    .id(page).transition(.opacity.combined(with: .scale(scale: 0.9)))
                Text(p.1).font(.system(size: 30, weight: .semibold)).id("t\(page)")
                Text(p.2).font(.system(size: 17)).foregroundStyle(Palette.soft).multilineTextAlignment(.center)
                    .lineSpacing(6).frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true).id("b\(page)")
                Spacer()
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule().fill(i == page ? Palette.glow : Color.white.opacity(0.25)).frame(width: i == page ? 22 : 8, height: 8)
                    }
                }
                Button {
                    if page + 1 < pages.count { withAnimation(.easeInOut(duration: 0.25)) { page += 1 } } else { done() }
                } label: {
                    Text(page + 1 < pages.count ? "下一步" : "开始使用").frame(width: 220).bigButton(primary: true)
                }.buttonStyle(.plain).padding(.bottom, 48)
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { d in
            withAnimation(.easeInOut(duration: 0.25)) {
                if d.translation.width < -40, page + 1 < pages.count { page += 1 }
                if d.translation.width > 40, page > 0 { page -= 1 }
            }
        })
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Full screen on the iPad; a sheet where there is no full-screen cover (the macOS test build).
    @ViewBuilder func fullScreenCoverIfAvailable<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}
