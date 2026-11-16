import Compression
import CoreML
import CryptoKit
import Foundation
import SwiftUI

/// Updates on the iPad (project/docs/update/UPDATE_MANIFEST.md, section "iPad"; one signed manifest for every platform).
/// Without a paid developer membership the app cannot replace its own code: for that it only says "a new version is in
/// AltStore" (`releases.ipad`). Its data can be updated: the component `models-ipad` (the Core ML models, a zip rooted
/// at `models/`) is downloaded into the app's own container and used instead of the copies built into the app.
/// What the privacy policy promises, and so what this does and nothing more:
///  - on by default; one check at start and about once a day while the app stays open; the switch "自动检查新版本"
///    turns it off, and then the app makes no network connection at all;
///  - the check downloads manifest.json and manifest.json.sig: no parameters, identifiers or cookies, only
///    `User-Agent: LRCDF/<version> (ipad)`; nothing is logged or kept;
///  - the Ed25519 signature is checked before the manifest is parsed; a manifest older than one already seen
///    (`published`), or naming an install target other than `models` for the iPad's component, is dropped;
///  - every piece is checked against its sha256 (and the joined file against sha256_joined) before anything is
///    unpacked; nothing but `models/…` may come out of the zip; on any mismatch everything staged is deleted;
///  - up to 60 MB is fetched without asking, more waits for a tap; new models are put in place at the next start
///    (no photos open), the user is told, and the replaced ones are kept for one step back.
@MainActor
final class UpdateNotice: ObservableObject {
    var offering: Bool { if case .offer = models { return true }; return false }     // the settings button shows a dot
    static let shared = UpdateNotice()
    static let publicKey = "KIaPbT+ihd/fLIOCt51e3HrS5ZykKWXtVuWlmiGU6kU="
    static let sources = ["https://gitee.com/YMLFPV/LRCDF/raw/update/manifest.json",
                          "https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/update/manifest.json"]
    static let quiet: Int64 = 60_000_000
    nonisolated static let component = "models-ipad"

    struct Newer: Equatable { let version: String; let note: String?; let unknownFormat: Bool }
    enum Models: Equatable { case none, offer(MB: Int), downloading(Double), staged, installed(String), failed(String) }

    // The manifest, as far as the iPad reads it (unknown fields are ignored).
    struct Piece: Decodable { let size: Int64; let sha256: String; let urls: [String] }
    struct Component: Decodable {
        let version: String; let files: [Piece]; let sha256_joined: String?; let install: Target
        enum Target: Decodable { case one(String), many([String])
            init(from d: Decoder) throws { let c = try d.singleValueContainer(); if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) } }
            var all: [String] { switch self { case .one(let s): [s]; case .many(let a): a } }
        }
    }
    struct Release: Decodable { let version: String; let notes: [String: String]?; let components: [String]? }
    struct Manifest: Decodable { let schema: Int; let published: String; let releases: [String: Release]?; let components: [String: Component]? }
    private struct Head: Decodable { let schema: Int; let published: String }

    @Published var newer: Newer?
    @Published var models: Models = .none
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "update.auto"); if enabled { Task { await check() } } }
    }
    private var timer: Timer?
    private var pending: Component?
    private init() { enabled = UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }

    nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Self-test only (DEBUG builds): another manifest address and another public key, for a local test server.
    private var environment: [String: String] {
        #if DEBUG
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }
    private var urls: [URL] { (environment["LRCDF_UPDATE_URL"].map { [$0] } ?? Self.sources).compactMap(URL.init(string:)) }
    private var key: String { environment["LRCDF_UPDATE_KEY"] ?? Self.publicKey }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral            // no cookies, no cache, nothing kept
        c.httpAdditionalHeaders = ["User-Agent": "LRCDF/\(Self.appVersion) (ipad)"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    /// Called once when the app's window appears.
    func start() {
        if let done = ModelStore.justInstalled { models = .installed(done) }
        guard timer == nil else { return }
        if enabled { Task { try? await Task.sleep(for: .seconds(4)); await check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                let me = UpdateNotice.shared
                let last = UserDefaults.standard.double(forKey: "update.lastCheck")
                if me.enabled, Date().timeIntervalSince1970 - last > 23 * 3600 { await me.check() }
            }
        }
    }

    func check() async {
        guard enabled else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "update.lastCheck")
        guard let (m, _) = await fetch() else { return }
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
        guard let m else {          // a newer format than this app knows: only say that a new version exists
            newer = Newer(version: "", note: nil, unknownFormat: true); return
        }
        guard let r = m.releases?["ipad"] else { return }
        newer = Self.isNewer(r.version, than: Self.appVersion) ? Newer(version: r.version, note: r.notes?[zh ? "zh" : "en"] ?? r.notes?["zh"], unknownFormat: false) : nil
        if r.components?.contains(Self.component) ?? false, let c = m.components?[Self.component],
           c.version != ModelStore.installedVersion, !ModelStore.isStaged(c.version) {
            pending = c
            let bytes = c.files.reduce(Int64(0)) { $0 + $1.size }
            // up to 60 MB by itself - unless the user went back from this very version: then only on a tap
            if bytes <= Self.quiet && c.version != ModelStore.wentBackFrom { await download() } else { models = .offer(MB: Int((Double(bytes) / 1e6).rounded(.up))) }
        }
    }

    /// The first source that answers with a manifest carrying a valid signature (and not older than one seen).
    /// Returns (nil, head) for a schema this app does not know.
    private func fetch() async -> (Manifest?, Head)? {
        guard let raw = Data(base64Encoded: key), let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        for url in urls {
            guard let (data, a) = try? await session.data(from: url), (a as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let (sigData, b) = try? await session.data(from: URL(string: url.absoluteString + ".sig")!), (b as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let text = String(data: sigData, encoding: .utf8),
                  let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pk.isValidSignature(sig, for: data)                       // the signature first: nothing is parsed before
            else { continue }
            guard let head = try? JSONDecoder().decode(Head.self, from: data) else { continue }
            let seen = UserDefaults.standard.string(forKey: "update.seen") ?? ""
            if head.published < seen { continue }                          // never backwards
            if head.schema > 1 { UserDefaults.standard.set(head.published, forKey: "update.seen"); return (nil, head) }
            guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            // the iPad's component may only install into `models`: anything else drops the manifest
            if let c = m.components?[Self.component], c.install.all != ["models"] { continue }
            UserDefaults.standard.set(head.published, forKey: "update.seen")
            return (m, head)
        }
        return nil
    }

    /// Downloads, checks, unpacks and compiles the pending models; they are put in place at the next start.
    func download() async {
        guard let c = pending else { return }
        models = .downloading(0)
        let total = Double(c.files.reduce(Int64(0)) { $0 + $1.size })
        do {
            let stage = ModelStore.staging
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            var joined = Data(), done = 0.0
            for (i, piece) in c.files.enumerated() {
                var got: Data?
                for u in piece.urls.compactMap(URL.init(string:)) {
                    guard enabled else { throw Fail.off }
                    if let (d, a) = try? await session.data(from: u), (a as? HTTPURLResponse)?.statusCode ?? 200 == 200 { got = d; break }
                }
                guard let d = got, d.count == piece.size, Self.hex(SHA256.hash(data: d)) == piece.sha256.lowercased() else { throw Fail.piece(i + 1) }
                joined.append(d); done += Double(d.count); models = .downloading(done / max(total, 1))
            }
            if c.files.count > 1 { guard let j = c.sha256_joined, Self.hex(SHA256.hash(data: joined)) == j.lowercased() else { throw Fail.joined } }
            let out = stage.appendingPathComponent("unpacked")
            try Unzip.extract(joined, to: out, onlyUnder: "models/")
            joined = Data()
            // compile every package here, once (MLModel needs the compiled form); one that does not compile fails it all
            let mdir = out.appendingPathComponent("models")
            for p in (try FileManager.default.contentsOfDirectory(at: mdir, includingPropertiesForKeys: nil)) where p.pathExtension == "mlpackage" {
                let compiled = try await MLModel.compileModel(at: p)
                let dest = mdir.appendingPathComponent(p.deletingPathExtension().lastPathComponent + ".mlmodelc")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: compiled, to: dest)
                try FileManager.default.removeItem(at: p)
            }
            try c.version.write(to: stage.appendingPathComponent("READY"), atomically: true, encoding: .utf8)
            models = .staged
        } catch {
            try? FileManager.default.removeItem(at: ModelStore.staging)
            models = .failed((error as? Fail)?.text ?? "新的修图模型没有通过检查，已丢弃。")
        }
        pending = nil
    }

    enum Fail: Error { case piece(Int), joined, off
        var text: String { switch self { case .piece(let n): "新模型的第 \(n) 块没有通过检查，已丢弃。"; case .joined: "新模型拼起来没有通过检查，已丢弃。"; case .off: "已关闭自动检查，下载停止。" } }
    }

    nonisolated static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
    /// "0.1.10" > "0.1.9": numbers compared one by one; anything else counts as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }
}

/// Where the models come from: an update installed in the app's container (Application Support/LRCDF/models/<name>.mlmodelc)
/// wins over the copy built into the app, model by model.
enum ModelStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LRCDF", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static var staging: URL { root.appendingPathComponent(".update", isDirectory: true) }
    static var previous: URL { root.appendingPathComponent(".previous", isDirectory: true) }
    private static var record: URL { root.appendingPathComponent(".components.json") }
    nonisolated(unsafe) static var justInstalled: String?

    static func url(_ name: String) -> URL? {
        let own = root.appendingPathComponent("models/\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: own.path) { return own }
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }
    /// The installed models-ipad version: the update's, or the one built into the app (BuildStamp.swift).
    static var installedVersion: String {
        (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?[UpdateNotice.component] ?? bundledModelsVersion
    }
    /// The models version the user went back from (not fetched again by itself).
    static var wentBackFrom: String? { try? String(contentsOf: root.appendingPathComponent(".wentback"), encoding: .utf8) }
    static func isStaged(_ v: String) -> Bool { (try? String(contentsOf: staging.appendingPathComponent("READY"), encoding: .utf8)) == v }
    static var canGoBack: Bool { FileManager.default.fileExists(atPath: previous.appendingPathComponent("components.json").path) }

    /// At start, before any model is loaded (no photos open): put staged models in place, or go one step back if asked.
    static func installIfReady() {
        let fm = FileManager.default
        let cur = root.appendingPathComponent("models")
        if fm.fileExists(atPath: root.appendingPathComponent(".goback").path) {
            try? fm.removeItem(at: root.appendingPathComponent(".goback"))
            guard canGoBack else { return }
            try? installedVersion.write(to: root.appendingPathComponent(".wentback"), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: cur)
            if fm.fileExists(atPath: previous.appendingPathComponent("models").path) { try? fm.moveItem(at: previous.appendingPathComponent("models"), to: cur) }
            try? fm.removeItem(at: record)
            if let old = try? Data(contentsOf: previous.appendingPathComponent("components.json")), old.count > 2 { try? old.write(to: record) }
            try? fm.removeItem(at: previous)
            justInstalled = "back"
            return
        }
        guard let v = try? String(contentsOf: staging.appendingPathComponent("READY"), encoding: .utf8) else { return }
        let new = staging.appendingPathComponent("unpacked/models")
        guard fm.fileExists(atPath: new.path) else { try? fm.removeItem(at: staging); return }
        try? fm.removeItem(at: previous)
        try? fm.createDirectory(at: previous, withIntermediateDirectories: true)
        if fm.fileExists(atPath: cur.path) { try? fm.moveItem(at: cur, to: previous.appendingPathComponent("models")) }
        let oldRecord = (try? Data(contentsOf: record)) ?? Data("{}".utf8)
        try? oldRecord.write(to: previous.appendingPathComponent("components.json"))
        do {
            try fm.moveItem(at: new, to: cur)
            try JSONEncoder().encode([UpdateNotice.component: v]).write(to: record)
            justInstalled = v
        } catch {                                   // leave the old models as they were
            if fm.fileExists(atPath: previous.appendingPathComponent("models").path) { try? fm.moveItem(at: previous.appendingPathComponent("models"), to: cur) }
        }
        try? fm.removeItem(at: staging)
    }
    static func goBack() { try? Data().write(to: root.appendingPathComponent(".goback")) }
}

/// Just enough of the zip format for a component (stored or deflated entries, read through the central directory).
/// Every entry must lie under `onlyUnder`; "..", absolute paths and links are refused.
enum Unzip {
    enum Bad: Error { case format, outside(String) }
    static func extract(_ z: Data, to dest: URL, onlyUnder prefix: String) throws {
        let b = [UInt8](z)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw Bad.format }
        var eocd = -1
        for i in stride(from: b.count - 22, through: max(0, b.count - 22 - 65_535), by: -1) where u32(i) == 0x06054b50 { eocd = i; break }
        guard eocd >= 0 else { throw Bad.format }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw Bad.format }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), attrs = u32(p + 38), local = u32(p + 42)
            guard p + 46 + nlen <= b.count, let name = String(bytes: b[(p + 46)..<(p + 46 + nlen)], encoding: .utf8) else { throw Bad.format }
            p += 46 + nlen + elen + clen
            if name.hasPrefix("__MACOSX/") || name.split(separator: "/").last.map({ $0.hasPrefix("._") }) == true { continue }
            guard name.hasPrefix(prefix), !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  (attrs >> 28) != 0xA else { throw Bad.outside(name) }                 // 0xA: a symbolic link
            let target = dest.appendingPathComponent(name)
            if name.hasSuffix("/") { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
            guard local + 30 <= b.count, u32(local) == 0x04034b50 else { throw Bad.format }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { throw Bad.format }
            let raw = Data(b[start..<(start + csize)])
            let out: Data
            switch method {
            case 0: out = raw
            case 8:
                var buf = [UInt8](repeating: 0, count: max(usize, 1))
                let n = raw.withUnsafeBytes { src in compression_decode_buffer(&buf, usize, src.bindMemory(to: UInt8.self).baseAddress!, csize, nil, COMPRESSION_ZLIB) }
                guard n == usize else { throw Bad.format }
                out = Data(buf.prefix(usize))
            default: throw Bad.format
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: target)
        }
    }
}

/// The bottom of the panel: a newer version, new models, and the switch.
struct UpdateRow: View {
    @ObservedObject var notice = UpdateNotice.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = notice.newer {
                Text(n.unknownFormat ? "有新版本" : "有新版本 \(n.version)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.glow)
                if let note = n.note { Text(note).font(.system(size: 12)).foregroundStyle(Palette.soft) }
                Text("新版本在 AltStore 里，打开 AltStore 点更新就行。").font(.system(size: 12)).foregroundStyle(Palette.soft)
            }
            switch notice.models {
            case .offer(let mb):
                Button { Task { await notice.download() } } label: { Text("下载新的修图模型（\(mb) MB）").font(.system(size: 13)) }
            case .downloading(let f):
                ProgressView(value: f) { Text("正在下载新的修图模型…").font(.system(size: 12)) }.tint(Palette.glow)
            case .staged:
                Text("新的修图模型已下载好，下次打开 app 时换上。").font(.system(size: 12)).foregroundStyle(Palette.glow)
            case .installed(let v):
                Text(v == "back" ? "已退回上一版修图模型。" : "修图模型已更新到新版本。").font(.system(size: 12)).foregroundStyle(Palette.glow)
            case .failed(let t):
                Text(t).font(.system(size: 12)).foregroundStyle(Palette.soft)
            case .none: EmptyView()
            }
            if ModelStore.canGoBack, notice.models != .staged {
                Button { ModelStore.goBack(); notice.models = .failed("下次打开 app 时退回上一版修图模型。") } label: {
                    Text("退回上一版修图模型").font(.system(size: 12))
                }.foregroundStyle(Palette.soft)
            }
            Toggle(isOn: $notice.enabled) { Text("自动检查新版本").font(.system(size: 13)) }
                .tint(Palette.glow)
            Text("只下载公开的版本说明和修图模型，并请 iPad 向苹果下载一次标题用的宋体；不发送任何照片或个人信息。关掉后完全不联网。“联机拍摄”只在你打开时接收同一局域网里相机发来的照片，不连接任何外部地址。")
                .font(.system(size: 11)).foregroundStyle(Palette.soft)
        }
        .padding(.top, 10)
    }
}
