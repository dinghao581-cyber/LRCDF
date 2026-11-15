import SwiftUI
import CryptoKit

/// Automatic updates, in parts. The contract is docs/update/UPDATE_MANIFEST.md: one signed manifest for every
/// platform; `releases["mac-arm64"]` names the components this app is made of and each is fetched only when its
/// version differs from what is installed (packaging/make_update.py makes them).
/// What the privacy policy promises, and so what this does and nothing more:
///  - on by default; one check when the app starts and about once a day while it is open;
///  - the check downloads one small public file (the manifest) and its signature; nothing about the user, the photos
///    or the catalog is sent, and nothing is recorded;
///  - the manifest must be signed with the project's key (the public half is below) or it is thrown away; every
///    piece is checked against the hash in the manifest before anything is unpacked;
///  - only what changed is downloaded; it is put in place when no photos are being worked on, and what it replaces
///    is kept for one step back;
///  - switched off in Settings, the app makes no network connection at all.
/// A developer's checkout (~/LRCDF/project/.git) is never touched.
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    static let publicKey = "KIaPbT+ihd/fLIOCt51e3HrS5ZykKWXtVuWlmiGU6kU="
    static let platform = "mac-arm64"
    static let schema = 1
    /// Tried in this order: the Gitee mirror (fast in China) once it exists, then GitHub.
    static let sources = ["https://gitee.com/YMLFPV/LRCDF/raw/update/manifest.json",
                          "https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/update/manifest.json"]
    static let downloadPage = "https://github.com/dinghao581-cyber/LRCDF/releases"
    /// Updates up to this size are fetched without asking; larger ones wait for a click.
    static let quiet: Int64 = 60_000_000
    /// What a component may be installed over, under ~/LRCDF: a manifest naming anything else is refused.
    static let targets: Set<String> = ["project", "project/runs", "models", "legacy", "python", "app"]

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(version: String, bytes: Int64)
        case downloading(version: String, done: Double)
        case ready(version: String)
        case tooNew                 // the manifest is of a newer kind than this app understands: send the user to the page
        case failed(String)
    }
    /// `install` is one target or a list of them.
    struct Targets: Decodable {
        let list: [String]
        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let many = try? box.decode([String].self) { list = many } else { list = [try box.decode(String.self)] }
        }
    }
    struct Piece: Decodable { let size: Int64; let sha256: String; let urls: [String] }
    struct Component: Decodable {
        let version: String; let install: Targets; let keep: [String]?; let restart: String?
        let files: [Piece]; let sha256_joined: String?
        var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }
    struct Release: Decodable { let version: String; let notes: [String: String]?; let components: [String] }
    struct Manifest: Decodable { let schema: Int; let published: String; let releases: [String: Release]; let components: [String: Component] }
    private struct Glance: Decodable { let schema: Int }

    @Published var state: State = .idle
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "update.auto") } }
    private var pending: (version: String, need: [(String, Component)])?
    private var timer: Timer?
    private var busy: () -> Bool = { false }
    private var progress: (Double) -> Void = { _ in }

    private let environment = ProcessInfo.processInfo.environment
    /// ~/LRCDF, or a stand-in for tests (LRCDF_HOME).
    var root: URL {
        if let other = environment["LRCDF_HOME"] { return URL(fileURLWithPath: other) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LRCDF")
    }
    private var staging: URL { root.appendingPathComponent(".update") }
    private var urls: [URL] { (environment["LRCDF_UPDATE_URL"].map { [$0] } ?? Self.sources).compactMap(URL.init(string:)) }
    private var isDeveloper: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("project/.git").path) }
    private var installed: [String: String]? {
        (try? Data(contentsOf: root.appendingPathComponent(".components.json"))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }
    var canGoBack: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".previous/components.json").path) }
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral           // no cookies, no cache, nothing kept
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        c.httpAdditionalHeaders = ["User-Agent": "LRCDF/\(version) (\(Self.platform))"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    override init() {
        enabled = UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true
        super.init()
    }

    /// Called once when the window appears. `busy` says whether photos are being worked on.
    func start(busy: @escaping () -> Bool) {
        self.busy = busy
        guard timer == nil else { return }
        if let version = try? String(contentsOf: staging.appendingPathComponent("READY"), encoding: .utf8), !isDeveloper {
            state = .ready(version: version.trimmingCharacters(in: .whitespacesAndNewlines))      // fetched last time: offer it at once
        } else if enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Task { await self.check(manual: false) } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.enabled, self.state == .idle || self.state == .upToDate else { return }
            let last = UserDefaults.standard.double(forKey: "update.lastCheck")
            if Date().timeIntervalSince1970 - last > 23 * 3600 { Task { await self.check(manual: false) } }
        }
    }

    @MainActor func check(manual: Bool) async {
        guard !isDeveloper, let have = installed else {
            if manual { state = .failed(L.updateNotInstalled) }
            return
        }
        if manual { state = .checking }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "update.lastCheck")
        switch await fetchManifest() {
        case .none: state = manual ? .failed(L.updateUnreachable) : .idle
        case .tooNew: state = .tooNew
        case .manifest(let manifest):
            guard let release = manifest.releases[Self.platform] else { state = manual ? .upToDate : .idle; return }
            let need = release.components.compactMap { id in manifest.components[id].map { (id, $0) } }.filter { have[$0.0] != $0.1.version }
            guard !need.isEmpty else { state = manual ? .upToDate : .idle; return }
            pending = (release.version, need)
            let bytes = need.reduce(Int64(0)) { $0 + $1.1.bytes }
            if bytes <= Self.quiet && !manual { await download() } else { state = .available(version: release.version, bytes: bytes) }
        }
    }

    private enum Answer { case none, tooNew, manifest(Manifest) }

    /// The first source that answers with a manifest carrying a valid signature. Nothing is read from it before the
    /// signature has been checked.
    private func fetchManifest() async -> Answer {
        guard let raw = Data(base64Encoded: Self.publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return .none }
        for url in urls {
            guard let (data, answer) = try? await session.data(from: url), (answer as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let (sigText, _) = try? await session.data(from: URL(string: url.absoluteString + ".sig")!),
                  let text = String(data: sigText, encoding: .utf8), let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  key.isValidSignature(sig, for: data) else { continue }
            if let glance = try? JSONDecoder().decode(Glance.self, from: data), glance.schema > Self.schema { return .tooNew }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.schema == Self.schema,
                  manifest.components.values.allSatisfy({ c in Set(c.install.list).isSubset(of: Self.targets) && (c.keep ?? []).allSatisfy { !$0.contains("..") } }) else { continue }
            // never an older manifest than one already seen: a genuine but outdated one could bring old faults back
            let seen = root.appendingPathComponent(".update_seen")
            if let newest = try? String(contentsOf: seen, encoding: .utf8), manifest.published < newest { continue }
            try? manifest.published.write(to: seen, atomically: true, encoding: .utf8)
            return .manifest(manifest)
        }
        return .none
    }

    @MainActor func download() async {
        guard let (version, need) = pending, var record = installed else { return }
        let total = Double(need.reduce(Int64(0)) { $0 + $1.1.bytes })
        state = .downloading(version: version, done: 0)
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var before = 0.0
            for (id, component) in need {
                let zip = staging.appendingPathComponent("\(id).zip")
                fm.createFile(atPath: zip.path, contents: nil)
                let out = try FileHandle(forWritingTo: zip)
                for piece in component.files {          // pieces are checked one by one, then joined in order
                    var got = false
                    for text in piece.urls {
                        guard let url = URL(string: text) else { continue }
                        progress = { [weak self] share in
                            DispatchQueue.main.async { self?.state = .downloading(version: version, done: (before + share * Double(piece.size)) / max(total, 1)) }
                        }
                        guard let (file, answer) = try? await session.download(from: url), (answer as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { continue }
                        defer { try? fm.removeItem(at: file) }
                        guard try Self.sha256(of: file) == piece.sha256 else { continue }
                        let part = try FileHandle(forReadingFrom: file)
                        while let block = try part.read(upToCount: 1 << 22), !block.isEmpty { try out.write(contentsOf: block) }
                        try part.close()
                        got = true; break
                    }
                    guard got else { throw Problem.text(L.updateBroken) }
                    before += Double(piece.size)
                }
                try out.close()
                if let joined = component.sha256_joined, try Self.sha256(of: zip) != joined { throw Problem.text(L.updateBroken) }
                let folder = staging.appendingPathComponent(id)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else { throw Problem.text(L.updateBroken) }
                try fm.removeItem(at: zip)
                // nothing but what the component owns may have come out of the zip
                let isApp = component.install.list == ["app"]
                let tops = Set(try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
                let allowed = isApp ? ["LRCDF.app"] : Set(component.install.list.map { $0.components(separatedBy: "/")[0] })
                guard tops.isSubset(of: allowed) else { throw Problem.text(L.updateBroken) }
                if isApp {
                    try fm.moveItem(at: folder, to: staging.appendingPathComponent("app"))
                } else {
                    try component.install.list.joined(separator: "\n").appending("\n").write(to: staging.appendingPathComponent("\(id).paths"), atomically: true, encoding: .utf8)
                    try (component.keep ?? []).joined(separator: "\n").appending("\n").write(to: staging.appendingPathComponent("\(id).keep"), atomically: true, encoding: .utf8)
                }
                record[id] = component.version
            }
            try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("components.json"))
            try version.write(to: staging.appendingPathComponent("READY"), atomically: true, encoding: .utf8)
            state = .ready(version: version)
        } catch {
            try? fm.removeItem(at: staging)
            state = .failed((error as? Problem)?.message ?? error.localizedDescription)
        }
    }

    /// Puts what was downloaded in place: the app quits, a small script swaps the folders and opens the app again.
    @MainActor func install() {
        guard case .ready = state, !busy() else { return }
        hand(["install", staging.path, Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier), root.path])
    }

    /// One step back: what the last update replaced comes back.
    @MainActor func goBack() {
        guard canGoBack, !busy() else { return }
        hand(["rollback", Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier), root.path])
    }

    private func hand(_ arguments: [String]) {
        guard let script = Bundle.main.url(forResource: "update_install", withExtension: "sh") else { state = .failed(L.updateBroken); return }
        // the script runs from a copy: the app it lives in is about to be replaced
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lrcdf_update_\(UUID().uuidString).sh")
        do { try FileManager.default.copyItem(at: script, to: copy) } catch { state = .failed(error.localizedDescription); return }
        state = .installing
        let quoted = ([copy.path] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let log = root.appendingPathComponent(".update.log").path
        _ = Self.run("/bin/bash", ["-c", "nohup /bin/bash \(quoted) > '\(log)' 2>&1 &"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    func later() { if state != .installing { state = .idle } }
    func openDownloadPage() { if let url = URL(string: Self.downloadPage) { NSWorkspace.shared.open(url) }; state = .idle }

    // MARK: pieces

    private enum Problem: Error { case text(String); var message: String { if case .text(let t) = self { return t }; return "" } }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The line at the bottom of the window that says an update is there, coming or ready. Quiet: it never covers the
/// photo and is not shown while photos are being worked on.
struct UpdateHost: View {
    @ObservedObject private var updater = Updater.shared
    @EnvironmentObject private var studio: Studio

    var body: some View {
        VStack {
            Spacer()
            if studio.stage != .working && studio.stage != .paused, let line = line {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(DS.ink)
                    Text(line.text).font(.system(size: 14)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if let action = line.action {
                        Button(action.title, action: action.run).buttonStyle(.plain).foregroundStyle(DS.focus)
                            .frame(height: DS.touch).contentShape(Rectangle())
                    }
                    if line.dismissable {
                        Button(L.updateLater) { updater.later() }.buttonStyle(.plain).foregroundStyle(DS.soft)
                            .frame(height: DS.touch).contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 6).frame(maxWidth: 760)
                .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .environment(\.colorScheme, .dark)
                .padding(DS.gap)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.stage, value: updater.state)
        .onAppear { updater.start { [weak studio] in studio.map { $0.stage == .working || $0.stage == .paused || $0.stage == .preparing } ?? false } }
    }

    private struct Line { let text: String; var action: (title: String, run: () -> Void)? = nil; var dismissable = true }
    private var line: Line? {
        switch updater.state {
        case .idle: return nil
        case .checking: return Line(text: L.updateChecking, dismissable: false)
        case .upToDate: return Line(text: L.updateNone)
        case .installing: return Line(text: L.updateInstalling, dismissable: false)
        case .available(let version, let bytes):
            return Line(text: L.updateAvailable(version, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)),
                        action: (L.updateDownload, { Task { await updater.download() } }))
        case .downloading(let version, let done):
            return Line(text: L.updateDownloading(version, Int((done * 100).rounded())), dismissable: false)
        case .ready(let version):
            return Line(text: L.updateReady(version), action: (L.updateInstall, { updater.install() }))
        case .failed(let why): return Line(text: why)
        case .tooNew: return Line(text: L.updateTooNew, action: (L.updateOpenPage, { updater.openDownloadPage() }))
        }
    }
}

/// Settings (⌘,): the switch the privacy policy promises, a manual check, and one step back.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Toggle(L.updateAuto, isOn: $updater.enabled)
            Text(L.updateAutoNote).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L.updateCheckNow) { Task { await updater.check(manual: true) } }
                if updater.canGoBack { Button(L.updateGoBack) { updater.goBack() } }
            }
        }
        .padding(24).frame(width: 440)
    }
}
