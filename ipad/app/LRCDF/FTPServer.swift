import Foundation
import ImageIO
import Network
import Security

/// 联机拍摄: a minimal FTP receiver for the camera's own "Auto FTP Transfer" (Sony A7R V, help guide
/// helpguide.sony.net/di/ftp_2230). The camera sends each photo as it is taken; a finished file goes through the normal
/// import. Plain FTP (the camera's Secure Protocol off), passive mode only (the camera has no active mode), listening on
/// the local network only, never connecting anywhere itself. Started by the user, stopped when they leave or the app
/// goes to the background.
///
/// Accepted: JPEG, HEIF, RAW (ARW, DNG). Video and anything else is accepted and thrown away (refusing it makes the
/// camera retry it forever). A file is handed on only when its data connection closed normally; half files are deleted.
final class FTPServer: @unchecked Sendable {
    static let port: UInt16 = 2121
    static let photoTypes: Set<String> = ["jpg", "jpeg", "hif", "heif", "heic", "arw", "dng"]

    private let queue = DispatchQueue(label: "lrcdf.ftp")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: FTPSession] = [:]
    let user: String, password: String
    let root: URL                                   // this session's receiving folder (tmp)
    var onFile: ((URL) -> Void)?                    // a complete photo (on the server's queue)
    var onState: ((String) -> Void)?                // "listening", "connected", "failed: …"

    init(user: String, password: String) {
        self.user = user; self.password = password
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let p = NWParameters.tcp
                p.prohibitedInterfaceTypes = [.cellular]  // the local network only (Wi-Fi, the iPad's own hotspot, USB)
                let l = try NWListener(using: p, on: NWEndpoint.Port(rawValue: Self.port)!)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] s in
                    switch s {
                    case .ready: self?.onState?("listening")
                    case .failed(let e): self?.onState?("failed: \(e)"); self?.stop()
                    default: break
                    }
                }
                l.start(queue: queue)
                listener = l
            } catch { onState?("failed: \(error)") }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            sessions.values.forEach { $0.close() }; sessions = [:]
        }
    }

    private func accept(_ c: NWConnection) {
        let s = FTPSession(c, server: self, queue: queue)
        let id = ObjectIdentifier(s)
        sessions[id] = s
        s.onEnd = { [weak self] in self?.sessions[id] = nil }
        s.start()
        onState?("connected")
    }

    private var pending: [String: Int] = [:]        // path -> generation: a newer upload of the same file wins

    /// An upload of `url` started (STOR / APPE): a finished copy still waiting is superseded.
    fileprivate func starting(_ url: URL) { pending[url.path, default: 0] += 1 }

    /// A finished upload: photos go to the import after a short wait (if the camera sends the same file again -
    /// a resume after a drop - only the last copy counts) and only if the file is whole; everything else is deleted.
    fileprivate func received(_ url: URL) {
        guard Self.photoTypes.contains(url.pathExtension.lowercased()) else { try? FileManager.default.removeItem(at: url); return }
        let gen = pending[url.path, default: 0]
        queue.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard pending[url.path, default: 0] == gen, FileManager.default.fileExists(atPath: url.path) else { return }
            pending[url.path] = nil
            if Self.whole(url) { onFile?(url) }
        }
    }

    /// A JPEG must end with its end marker; HEIF and RAW must open as an image with a size.
    static func whole(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            guard let h = try? FileHandle(forReadingFrom: url), let end = try? h.seekToEnd(), end > 4 else { return false }
            try? h.seek(toOffset: end - 2); let tail = (try? h.read(upToCount: 2)) ?? Data(); try? h.close()
            return tail == Data([0xFF, 0xD9])
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
    }

    // MARK: login

    /// The login the camera is set up with once: made at first use and kept in the keychain (never logged).
    static func credentials() -> (String, String) {
        let user = UserDefaults.standard.string(forKey: "ftpUser") ?? "lrcdf"     // the user name is not a secret
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "lrcdf.ftp",
                                kSecAttrAccount as String: "lrcdf", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let p = String(data: d, encoding: .utf8) {
            return (user, p)
        }
        // easy to type on the camera: letters and digits, no look-alikes
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let p = String(bytes.map { chars[Int($0) % chars.count] })
        savePassword(p)
        return (user, p)
    }

    /// What the camera accepts and can be typed on it: letters, digits and - _ . @, 1-32 characters (nil = fine).
    static func problem(user: String, password: String) -> String? {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        if user.isEmpty || user.count > 32 { return "用户名要 1 到 32 个字符。" }
        if password.count < 4 || password.count > 32 { return "密码要 4 到 32 个字符。" }
        if !user.allSatisfy({ ok.contains($0) }) || !password.allSatisfy({ ok.contains($0) }) {
            return "只能用英文字母、数字和 - _ . @（相机上好输入），不能有空格和中文。"
        }
        return nil
    }

    /// The user's own login (联机拍摄 → 修改): user name in the settings, password in the keychain (this device only).
    static func save(user: String, password: String) {
        UserDefaults.standard.set(user, forKey: "ftpUser")
        savePassword(password)
    }
    private static func savePassword(_ p: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "lrcdf.ftp", kSecAttrAccount as String: "lrcdf"]
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: Data(p.utf8)] as CFDictionary) == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = Data(p.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// The iPad's local IPv4 addresses: Wi-Fi (en0) first, then its own hotspot (bridge100).
    static func addresses() -> [(String, String)] {
        var out: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            out.append((name, String(cString: host)))
        }
        return out.sorted { ($0.0 == "en0" ? 0 : $0.0.hasPrefix("bridge") ? 1 : 2) < ($1.0 == "en0" ? 0 : $1.0.hasPrefix("bridge") ? 1 : 2) }
    }
}

/// One control connection.
private final class FTPSession {
    private let c: NWConnection
    private weak var server: FTPServer?
    private let queue: DispatchQueue
    private var buffer = Data()
    private var userGiven: String?
    private var loggedIn = false
    private var cwd = "/"                           // virtual path below the server's root
    private var type = "I"
    private var restAt: UInt64 = 0
    private var dataListener: NWListener?
    private var dataConn: NWConnection?
    private var waiting: ((NWConnection) -> Void)?   // a transfer waiting for the camera's data connection
    private var renameFrom: URL?
    var onEnd: (() -> Void)?

    init(_ c: NWConnection, server: FTPServer, queue: DispatchQueue) { self.c = c; self.server = server; self.queue = queue }

    func start() {
        c.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.close() }
            if case .cancelled = s { self?.onEnd?() }
        }
        c.start(queue: queue)
        reply("220 LRCDF ready")
        read()
    }

    func close() {
        dataListener?.cancel(); dataConn?.cancel(); c.cancel()
    }

    private func reply(_ s: String) { c.send(content: Data((s + "\r\n").utf8), completion: .contentProcessed { _ in }) }

    private func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let r = self.buffer.firstRange(of: Data([13, 10])) ?? self.buffer.firstRange(of: Data([10])) {
                let line = String(decoding: self.buffer[..<r.lowerBound], as: UTF8.self)
                self.buffer.removeSubrange(..<r.upperBound)
                self.command(line)
            }
            if done || err != nil { self.close(); return }
            self.read()
        }
    }

    // MARK: paths

    /// A virtual path made absolute and checked: nothing outside the root, no "..".
    private func resolve(_ arg: String) -> (String, URL)? {
        let raw = arg.replacingOccurrences(of: "\\", with: "/")
        let parts = (raw.hasPrefix("/") ? raw : cwd + "/" + raw).split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains(".."), let root = server?.root else { return nil }
        let path = "/" + parts.joined(separator: "/")
        return (path, parts.reduce(root) { $0.appendingPathComponent($1) })
    }

    // MARK: commands

    private func command(_ line: String) {
        let sp = line.firstIndex(of: " ")
        let verb = String(sp.map { line[..<$0] } ?? Substring(line)).uppercased()
        let arg = sp.map { String(line[line.index(after: $0)...]) } ?? ""
        let open: Set<String> = ["USER", "PASS", "QUIT", "SYST", "FEAT", "NOOP", "OPTS", "AUTH"]
        if !loggedIn && !open.contains(verb) { reply("530 Please log in"); return }
        let fm = FileManager.default
        switch verb {
        case "USER": userGiven = arg; loggedIn = false; reply("331 Password required")
        case "PASS":
            if let server, userGiven == server.user, arg == server.password { loggedIn = true; reply("230 Logged in") }
            else { loggedIn = false; reply("530 Login incorrect") }
        case "AUTH": reply("502 Plain FTP only (set Secure Protocol Off)")
        case "SYST": reply("215 UNIX Type: L8")
        case "FEAT": reply("211-Features:\r\n PASV\r\n EPSV\r\n SIZE\r\n REST STREAM\r\n UTF8\r\n211 End")
        case "OPTS": reply("200 OK")
        case "NOOP": reply("200 OK")
        case "PWD", "XPWD": reply("257 \"\(cwd)\"")
        case "TYPE": type = arg.uppercased().hasPrefix("A") ? "A" : "I"; reply("200 Type \(type)")
        case "MODE", "STRU": reply("200 OK")
        case "CWD", "XCWD":
            guard let (path, url) = resolve(arg) else { reply("550 Not allowed"); return }
            var dir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue { cwd = path; reply("250 OK") } else { reply("550 No such directory") }
        case "CDUP", "XCUP":
            cwd = "/" + cwd.split(separator: "/").dropLast().joined(separator: "/"); reply("250 OK")
        case "MKD", "XMKD":
            guard let (path, url) = resolve(arg) else { reply("550 Not allowed"); return }
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true); reply("257 \"\(path)\" created") }
            catch { reply("550 Cannot create") }
        case "RMD", "DELE":
            reply("550 Not allowed")
        case "SIZE":
            guard let (_, url) = resolve(arg), let n = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { reply("550 No such file"); return }
            reply("213 \(n)")
        case "MDTM": reply("550 Not available")
        case "REST": restAt = UInt64(arg) ?? 0; reply("350 Restarting at \(restAt)")
        case "PASV": passive(extended: false)
        case "EPSV": passive(extended: true)
        case "PORT", "EPRT": reply("502 Passive mode only")
        case "STOR", "APPE":
            guard let (_, url) = resolve(arg) else { reply("553 Not allowed"); return }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            store(url, append: verb == "APPE")
        case "LIST", "NLST", "MLSD":
            transfer { [weak self] conn in
                guard let self else { return }
                let dir = self.resolve("")?.1
                let names = (try? fm.contentsOfDirectory(atPath: dir?.path ?? "")) ?? []
                let text = names.map { verb == "NLST" ? $0 : "-rw-r--r-- 1 lrcdf lrcdf 0 Jan 1 00:00 \($0)" }.joined(separator: "\r\n")
                conn.send(content: Data((text.isEmpty ? "" : text + "\r\n").utf8), isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel(); self.reply("226 Done")
                })
            }
        case "RNFR":
            guard let (_, url) = resolve(arg), fm.fileExists(atPath: url.path) else { reply("550 No such file"); return }
            renameFrom = url; reply("350 Ready")
        case "RNTO":
            guard let from = renameFrom, let (_, to) = resolve(arg) else { reply("503 RNFR first"); return }
            renameFrom = nil
            try? fm.removeItem(at: to)
            do { try fm.moveItem(at: from, to: to); reply("250 Renamed"); server?.received(to) } catch { reply("550 Cannot rename") }
        case "QUIT": c.send(content: Data("221 Bye\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.c.cancel() })
        default: reply("502 Not implemented")
        }
    }

    /// PASV / EPSV: a listener on any free port, on the address the camera reached us at.
    private func passive(extended: Bool) {
        dataListener?.cancel(); dataConn?.cancel(); dataConn = nil
        let p = NWParameters.tcp
        guard let l = try? NWListener(using: p, on: .any) else { reply("425 Cannot open data connection"); return }
        dataListener = l
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            if let w = self.waiting { self.waiting = nil; w(conn) } else { self.dataConn = conn }
            l.cancel()
        }
        l.stateUpdateHandler = { [weak self] s in
            guard let self, case .ready = s, let port = l.port?.rawValue else { return }
            if extended { self.reply("229 Entering Extended Passive Mode (|||\(port)|)"); return }
            var host = "127.0.0.1"
            if case .hostPort(let h, _)? = self.c.currentPath?.localEndpoint, case .ipv4(let a) = h {
                host = a.rawValue.map(String.init).joined(separator: ".")
            }
            self.reply("227 Entering Passive Mode (\(host.replacingOccurrences(of: ".", with: ",")),\(port >> 8),\(port & 255))")
        }
        l.start(queue: queue)
    }

    /// Runs `body` with the data connection, now or when the camera opens it.
    private func transfer(_ body: @escaping (NWConnection) -> Void) {
        reply("150 Opening data connection")
        if let d = dataConn { dataConn = nil; body(d) }
        else if dataListener != nil { waiting = body }
        else { reply("425 Use PASV first") }
    }

    private func store(_ url: URL, append: Bool) {
        let offset = restAt; restAt = 0
        server?.starting(url)
        let fm = FileManager.default
        let part = url.appendingPathExtension("part")
        if append || offset > 0 {               // a resumed upload: go on from the half file (or from the finished one)
            if !fm.fileExists(atPath: part.path), fm.fileExists(atPath: url.path) { try? fm.moveItem(at: url, to: part) }
        } else { try? fm.removeItem(at: part) }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: part) else { reply("550 Cannot write"); return }
        if offset > 0 { try? h.truncate(atOffset: offset) } else if append { _ = try? h.seekToEnd() } else { try? h.truncate(atOffset: 0) }
        transfer { [weak self] conn in
            func next() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
                    if let data, !data.isEmpty { try? h.write(contentsOf: data) }
                    if err != nil {                      // broken off: the half file stays (for REST / APPE), never imported
                        try? h.close()
                        conn.cancel(); self?.reply("426 Transfer aborted"); return
                    }
                    if done {
                        try? h.close(); conn.cancel()
                        try? FileManager.default.removeItem(at: url)
                        try? FileManager.default.moveItem(at: part, to: url)
                        self?.reply("226 Transfer complete")
                        self?.server?.received(url)
                        return
                    }
                    next()
                }
            }
            next()
        }
    }
}
