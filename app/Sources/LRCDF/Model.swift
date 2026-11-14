import AppKit
import SwiftUI

struct Session: Codable, Equatable {
    var time: Double
    var active: Int
    var ids: [Int]
    var name: String
    var iso: Int?
}

struct Look: Identifiable, Equatable {
    let id: String          // "none", "a" … "f", or "u…" for the user's own
    let title: String
    let note: String
    let image: NSImage
    var mine: Bool { id.hasPrefix("u") }
    // the same look of another photo is a different picture
    static func == (a: Look, b: Look) -> Bool { a.id == b.id && a.image === b.image }
}

/// Everything shown for one photo: its looks, where they are kept, and where its faces are.
struct PhotoPreview {
    var looks: [Look]
    var folder: URL
    var faces: [CGRect] = []          // fractions of the picture, largest first
}

enum BeautyLevel: String, CaseIterable, Identifiable {
    case off, auto, natural, refined
    var id: String { rawValue }
    var title: String { ["off": "不美颜", "auto": "自动", "natural": "自然", "refined": "精致"][rawValue]! }
    var note: String {
        ["off": "只调色，不动皮肤", "auto": "每张脸各选一档：修不过头的前提下尽量干净（推荐）", "natural": "看不出修过", "refined": "更干净，适合特写"][rawValue]!
    }
}

/// Small nudges on top of a look, each from -2 to 2.
struct Tweak: Equatable, Codable {
    var bright = 0, warm = 0, rich = 0
    var isZero: Bool { bright == 0 && warm == 0 && rich == 0 }
    var argument: String { "\(bright),\(warm),\(rich)" }
}

/// Someone who appears in the photos handed over (found by the selection help), and can get their own retouching.
struct Person: Identifiable, Equatable {
    let id: Int
    let image: NSImage
    let photos: Int
    var vector: [Float] = []          // what their face looks like to the recogniser (unit length)
    var auto = ""                     // "light" for a man or a child, as far as that could be told
    static func == (a: Person, b: Person) -> Bool { a.id == b.id && a.photos == b.photos }
}

/// One go at retouching: what was asked, how far it got, and what is needed to undo it. Kept on disk.
struct Run: Codable, Equatable {
    var id: String
    var ids: [Int]
    var look: String
    var level: String
    var slim: Bool
    var denoise: Bool
    var tweak: Tweak
    var shapes: [String]? = nil       // of "slim", "bigeyes", "chest", "waist", "legs"
    var people: String? = nil         // own retouching for some people: "3:off,5:refined"
    var best: Bool? = nil             // 16-bit wide-gamut pictures (missing in runs from before this existed)
    var saved = false                 // the photos' settings before the run are on disk
    var denoised: [Int] = []          // photos the denoise step has been through
    var denoiseSwitched: [Int] = []   // … and those it actually switched on (for undo)
    var toned = false
    var done: [Int] = []
    var failed: [Int] = []
    var created: [String: Int] = [:]  // original id -> id of the retouched picture
    var finished = false
    var undone = false

    var settingsFile: URL { Bridge.undo.appendingPathComponent("\(id).lua") }
    var remaining: Int { ids.count - done.count - failed.count }
}

enum Stage: Equatable {
    case waiting                      // nothing sent from Lightroom yet
    case preparing                    // pictures of the looks are being made for the first photo
    case choosing
    case working
    case paused
    case finished
    case reviewing                    // looking at the finished pictures
    case failed(String)
}

@MainActor
final class Studio: ObservableObject {
    @Published var stage: Stage = .waiting
    @Published var session: Session?
    @Published var photo: Int = 0                         // the photo being looked at
    @Published var previews: [Int: PhotoPreview] = [:]
    @Published var thumbs: [Int: NSImage] = [:]
    @Published var flags: [Int: [String]] = [:]           // "blur", "eyes" per photo, once judged
    @Published var people: [Person] = []                  // the people in these photos, most frequent first
    /// What each of them gets: "follow" (the general level), "light", "natural", "refined" or "off". Set when the
    /// person is first seen: what was chosen for them last time, else "light" for men and children, else "follow".
    @Published var choices: [Int: String] = [:] { didSet { wantPictures() } }
    private var everyone: Set<Int> = []                    // all people found, also those beyond the six shown
    static let knownFile = Bridge.root.appendingPathComponent("known_people.json")
    private static func alike(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func known() -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: knownFile))) as? [[String: Any]]) ?? []
    }
    /// The user's choice for a person; remembered with their face for the next shoots (the last 300 people).
    func choose(_ value: String, for person: Person) {
        choices[person.id] = value
        guard !person.vector.isEmpty else { return }
        var list = Self.known().filter { entry in
            guard let v = entry["vec"] as? [Double] else { return false }
            return Self.alike(v.map(Float.init), person.vector) < 0.4
        }
        list.append(["vec": person.vector.map(Double.init), "choice": value])
        if let data = try? JSONSerialization.data(withJSONObject: Array(list.suffix(300))) { try? data.write(to: Self.knownFile, options: .atomic) }
    }
    static let peopleFile = Bridge.before.appendingPathComponent("people.json")
    private var choiceList: String {
        level == .off ? "" : choices.filter { pair in pair.value != "follow" && everyone.contains(pair.key) }.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }
    private var choiceArguments: [(String, String)] {
        (choiceList.isEmpty ? [] : [("people", choiceList)]) + (people.isEmpty || level == .off ? [] : [("peoplefile", Self.peopleFile.path)])
    }
    @Published var loading: Int?                          // a photo whose looks are being made
    @Published var pictures: [String: NSImage] = [:]      // tweaked and beautified previews, by key
    @Published var making: Set<String> = []
    @Published var face: Int?                             // the face last jumped to
    @Published var zoom: CGFloat = 1                      // 1 = the whole picture fits
    @Published var centre = CGPoint(x: 0.5, y: 0.5)       // the point of the picture in the middle of the view
    @Published var look: String = UserDefaults.standard.string(forKey: "look") ?? "d" { didSet { wantPictures() } }
    @Published var level: BeautyLevel = BeautyLevel(rawValue: UserDefaults.standard.string(forKey: "beautyLevel") ?? "") ?? .auto {      // 自动 is the default; a later choice is remembered
        didSet { wantPictures() }
    }
    /// Shaping that is switched on: "slim", "bigeyes", "chest", "waist", "legs".
    @Published var shapes: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shapes") ?? []) { didSet { wantPictures() } }
    static let shapeOrder = ["slim", "bigeyes", "chest", "waist", "legs", "light"]      // light = 匀光: not a shape, but a switch like them
    private var shapeList: [String] { level == .off ? [] : Self.shapeOrder.filter { shapes.contains($0) } }
    @Published var tweak = Tweak() { didSet { wantPictures() } }
    @Published var denoise: Bool = UserDefaults.standard.bool(forKey: "denoise")
    @Published var best: Bool = UserDefaults.standard.bool(forKey: "best")   // keep the most picture quality
    @Published var skipFlagged = false
    @Published var fraction: Double = 0
    @Published var caption: String = ""
    @Published var lightroomOpen = Bridge.lightroomIsOpen()
    @Published var run: Run?                              // in progress, paused, or the last one
    @Published var pauseAsked = false
    @Published var notice: String?                        // a line under the result (undo done, …)
    @Published var styleError: String?
    @Published var savingStyle = false
    @Published var results: [Int: NSImage] = [:]          // finished pictures, by original id
    @Published var befores: [Int: NSImage] = [:]

    private var seen: Double = 0
    private var ticker: Timer?
    private var wish = 0
    private var culling = false
    private var chunkBase = 0.0, chunkSpan = 0.0

    var looks: [Look] { previews[photo]?.looks ?? [] }
    var faces: [CGRect] { previews[photo]?.faces ?? [] }
    var original: Look? { looks.first { $0.id == "none" } }
    var chosen: Look? { looks.first { $0.id == look } }
    var count: Int { session?.ids.count ?? 0 }
    var flagged: [Int] { (session?.ids ?? []).filter { !(flags[$0] ?? []).isEmpty } }
    /// The photos a click on the button would retouch.
    var targets: [Int] { (session?.ids ?? []).filter { !skipFlagged || (flags[$0] ?? []).isEmpty } }
    var nothingToDo: Bool { (look == "none" && level == .off && !denoise) || targets.isEmpty }
    /// High ISO photos are worth denoising; the switch says so.
    var noisy: Bool { (session?.iso ?? 0) >= 1600 }
    var busy: Bool { stage == .preparing || stage == .working || loading != nil || !making.isEmpty || culling || savingStyle }

    // MARK: pictures on the "after" side

    private var tweakNow: Tweak { look == "none" ? Tweak() : tweak }
    private func lookKey(_ t: Tweak) -> String { "\(photo)|\(look)|\(t.argument)" }
    private func beautyKey(_ t: Tweak, _ level: BeautyLevel) -> String {
        "\(photo)|\(look)|\(t.argument)|\(level.rawValue)|\(shapeList.joined(separator: "+"))|\(choiceList)"
    }
    /// The look, with the tweak: Lightroom's picture when it is ready, until then an immediate approximation (Quick).
    private var base: NSImage? {
        if tweakNow.isZero { return chosen?.image }
        if let exact = pictures[lookKey(tweakNow)] { return exact }
        guard let plain = chosen?.image else { return nil }
        return Quick.picture(plain, key: "\(photo)|\(look)", tweak: tweakNow)
    }
    /// What the "after" side shows: look, tweak and beautification, as far as they are ready. While a tweaked picture
    /// is on its way, the tweak is approximated on the beautified picture of the untouched look, so the face does not
    /// jump back to unretouched.
    var after: NSImage? {
        if level == .off { return base }
        if let exact = pictures[beautyKey(tweakNow, level)] { return exact }
        if !tweakNow.isZero, let plain = pictures[beautyKey(Tweak(), level)] {
            return Quick.picture(plain, key: beautyKey(Tweak(), level), tweak: tweakNow)
        }
        return base
    }
    var beautyShown: Bool { level != .off && pictures[beautyKey(tweakNow, level)] != nil }
    var pictureExact: Bool {
        (tweakNow.isZero || pictures[lookKey(tweakNow)] != nil) && (level == .off || beautyShown)
    }

    func start() {
        if let data = try? Data(contentsOf: Bridge.run), let last = try? JSONDecoder().decode(Run.self, from: data) { run = last }
        check()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Lightroom hands over photos by writing a new session file.
    private func check() {
        lightroomOpen = Bridge.lightroomIsOpen() || busy
        if stage == .working, let text = try? String(contentsOf: Bridge.progress, encoding: .utf8) {
            let parts = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            if let value = Double(parts[0]) {
                withAnimation(.easeOut(duration: 0.4)) { fraction = max(fraction, chunkBase + chunkSpan * value) }
            }
            if parts.count > 1, !parts[1].isEmpty { caption = parts[1] }
        }
        guard stage != .preparing, stage != .working, stage != .paused,
              let data = try? Data(contentsOf: Bridge.session),
              let incoming = try? JSONDecoder().decode(Session.self, from: data),
              incoming.time > seen else { return }
        // a session left over from an earlier day is not a request
        let fresh = Date().timeIntervalSince1970 - incoming.time < 120
        seen = incoming.time
        if fresh { open(incoming) }
    }

    private func open(_ incoming: Session) {
        session = incoming
        previews = [:]; thumbs = [:]; pictures = [:]; Quick.forget(); making = []; flags = [:]; face = nil; loading = nil
        people = []; choices = [:]; everyone = []
        zoom = 1; centre = CGPoint(x: 0.5, y: 0.5); tweak = Tweak(); skipFlagged = false; notice = nil
        photo = incoming.active
        stage = .preparing
        NSApp.activate(ignoringOtherApps: true)
        if incoming.ids.count > 1 { loadThumbs(incoming) }
        Task {
            do {
                try await loadLooks(of: incoming.active)
                withAnimation(.easeInOut(duration: 0.5)) { stage = .choosing }
                wantPictures()
                judge(incoming)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Small pictures of every photo that was handed over, for the strip on the left.
    private func loadThumbs(_ incoming: Session) {
        let ids = Array(incoming.ids.prefix(120))
        Task {
            guard let lines = try? await Bridge.send([("action", "thumbs"), ("size", "240"), ("dir", Bridge.thumbs.path),
                                                      ("ids", ids.map(String.init).joined(separator: ","))], timeout: 300) else { return }
            guard session == incoming else { return }
            for (id, image) in Self.images(lines) { thumbs[id] = image }
        }
    }

    private static func images(_ lines: [String]) -> [(Int, NSImage)] {
        lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let id = Int(parts[0]), let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])),
                  let image = NSImage(data: data) else { return nil }
            return (id, image)
        }
    }

    /// Selection help: closed eyes and out-of-focus photos get a mark on the strip. A few photos at a time, so that
    /// whatever the user clicks meanwhile is not kept waiting long.
    private func judge(_ incoming: Session) {
        guard !culling else { return }
        culling = true
        Task {
            var rest = incoming.ids
            var first = true
            while !rest.isEmpty, session == incoming {
                if stage == .working || stage == .paused || stage == .finished || stage == .reviewing { break }
                let chunk = Array(rest.prefix(6)); rest.removeFirst(chunk.count)
                guard let lines = try? await Bridge.send([("action", "cull"), ("size", "1400"), ("dir", Bridge.before.path), ("fresh", first ? "1" : "0"),
                                                          ("ids", chunk.map(String.init).joined(separator: ","))], timeout: 240) else { break }
                guard session == incoming else { break }
                first = false
                readPeople()
                for line in lines {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 2, let id = Int(parts[0]) {
                        flags[id] = parts[1].split(separator: ",").map(String.init)
                    }
                }
            }
            culling = false
        }
    }

    /// The looks of a photo. Lightroom renders them one after the other (about five seconds each), so the look on
    /// screen comes first and the photo is shown with it; the other cards fill in one by one behind whatever the user
    /// asks for meanwhile.
    private func loadLooks(of id: Int) async throws {
        let wanted = look == "none" ? "d" : look
        let (found, folder, missing) = try await askLooks(of: id, only: "none,\(wanted)")
        guard let folder, found.contains(where: { $0.id == "none" }), found.count > 1 else {
            throw Bridge.Failure.refused("没有拿到这张照片的预览。")
        }
        if !found.contains(where: { $0.id == look }) { look = found.first(where: { $0.id != "none" })?.id ?? "d" }
        previews[id] = PhotoPreview(looks: found, folder: folder, faces: readFaces(folder))
        guard !missing.isEmpty else { return }
        let incoming = session
        Task {
            for name in missing {
                try? await Task.sleep(nanoseconds: 700_000_000)
                while !making.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }     // the user's wishes first
                guard session == incoming, stage == .choosing, previews[id] != nil else { return }
                guard let (more, _, _) = try? await askLooks(of: id, only: name), session == incoming, previews[id] != nil else { continue }
                withAnimation(.easeInOut(duration: 0.3)) { previews[id]?.looks = more }
            }
        }
    }

    /// (the looks that exist, their folder, the ones still to be made)
    private func askLooks(of id: Int, only: String) async throws -> ([Look], URL?, [String]) {
        let lines = try await Bridge.send([("action", "previews"), ("size", "2600"), ("only", only),
                                           ("dir", Bridge.previews.path), ("ids", String(id))], timeout: 300)
        var found: [Look] = []
        var missing: [String] = []
        var folder: URL?
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let image = NSImage(data: data) else {
                missing.append(parts[0]); continue
            }
            folder = URL(fileURLWithPath: parts[1]).deletingLastPathComponent()
            found.append(Look(id: parts[0], title: parts[2], note: parts[3], image: image))
        }
        return (found, folder, missing)
    }

    private func readFaces(_ folder: URL) -> [CGRect] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("faces.json")),
              let boxes = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return boxes.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) }
    }

    /// Look at another of the photos. Its looks are made the first time (about 20 seconds).
    func show(_ id: Int) {
        if stage == .reviewing { review(id); return }
        guard stage == .choosing, loading == nil, id != photo else { return }
        face = nil; zoom = 1; centre = CGPoint(x: 0.5, y: 0.5)
        if previews[id] != nil {
            withAnimation(.easeInOut(duration: 0.3)) { photo = id }
            wantPictures()
            return
        }
        loading = id
        Task {
            do {
                try await loadLooks(of: id)
                withAnimation(.easeInOut(duration: 0.3)) { photo = id }
                loading = nil
                wantPictures()
            } catch {
                loading = nil
            }
        }
    }

    /// Asks Lightroom's side for the pictures of what is on screen — the tweaked look, then its beautified versions —
    /// unless they are there. Waits a moment first, so that stepping through tweaks does not queue up every stop.
    /// The people found so far: those seen clearly, the ones in most photos first, at most six.
    private func readPeople() {
        guard let data = try? Data(contentsOf: Self.peopleFile),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = top["people"] as? [[String: Any]] else { return }
        let found: [(Person, Int)] = list.compactMap { p in
            guard let id = p["id"] as? Int, let thumb = p["thumb"] as? String, let width = p["width"] as? Int, width >= 60,
                  let bytes = try? Data(contentsOf: URL(fileURLWithPath: thumb)), let image = NSImage(data: bytes) else { return nil }
            return (Person(id: id, image: image, photos: (p["photos"] as? [Any])?.count ?? 1,
                           vector: ((p["vec"] as? [Double]) ?? []).map(Float.init), auto: (p["auto"] as? String) ?? ""), width)
        }
        let all = found.sorted { ($0.0.photos, $0.1) > ($1.0.photos, $1.1) }.map { $0.0 }
        let sorted = Array(all.prefix(6))
        everyone = Set(all.map { $0.id })
        let memory = sorted.count > 1 ? Self.known() : []      // one person alone: the general level is theirs
        for person in all where sorted.count > 1 && choices[person.id] == nil {
            let best = memory.compactMap { entry -> (Float, String)? in
                guard let v = entry["vec"] as? [Double], let c = entry["choice"] as? String else { return nil }
                return (Self.alike(v.map(Float.init), person.vector), c)
            }.max { $0.0 < $1.0 }
            choices[person.id] = (best.map { $0.0 >= 0.4 } == true ? best!.1 : nil) ?? (person.auto.isEmpty ? "follow" : person.auto)
        }
        if sorted != people { withAnimation(.easeInOut(duration: 0.3)) { people = sorted } }
    }

    private func wantPictures() {
        wish += 1
        let mine = wish
        guard stage == .choosing, previews[photo] != nil, chosen != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard mine == wish, stage == .choosing, let preview = previews[photo] else { return }
            let (id, style, t, lvl, shaped, own, ownArguments) = (photo, look, tweakNow, level, shapeList, choiceList, choiceArguments)
            var name = style
            if !t.isZero {
                let key = lookKey(t)
                name = "\(style)_t\(t.bright)_\(t.warm)_\(t.rich)"
                if pictures[key] == nil {
                    guard !making.contains(key) else { return }
                    making.insert(key)
                    let lines = (try? await Bridge.send([("action", "tweakpreview"), ("dir", preview.folder.path), ("look", style),
                                                         ("tweak", t.argument), ("size", "2600"), ("ids", String(id))], timeout: 120)) ?? []
                    making.remove(key)
                    guard let parts = lines.first?.components(separatedBy: "\t"), parts.count >= 2,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let image = NSImage(data: data) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { pictures[key] = image }
                }
            }
            guard lvl != .off else { return }
            let keys = [BeautyLevel.auto, .natural, .refined].map { ($0, "\(id)|\(style)|\(t.argument)|\($0.rawValue)|\(shaped.joined(separator: "+"))|\(own)") }
            guard let wanted = keys.first(where: { $0.0 == lvl })?.1, pictures[wanted] == nil, !making.contains(wanted) else { return }
            keys.forEach { making.insert($0.1) }
            let lines = (try? await Bridge.send([("action", "beautypreview"), ("dir", preview.folder.path), ("look", name),
                                                 ("levels", "auto,natural,refined")] + shaped.map { ($0, "1") } + ownArguments, timeout: 240)) ?? []
            for line in lines {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, let pair = keys.first(where: { $0.0.rawValue == parts[0] }),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let image = NSImage(data: data) else { continue }
                withAnimation(.easeInOut(duration: 0.35)) { pictures[pair.1] = image }
            }
            keys.forEach { making.remove($0.1) }
            if previews[id]?.faces.isEmpty == true { previews[id]?.faces = readFaces(preview.folder) }
        }
    }

    // MARK: zooming

    /// Zoom by a factor, keeping the point under `anchor` (0…1 across the view) where it is.
    func zoom(by factor: CGFloat, at anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let next = min(8, max(1, zoom * factor))
        let under = CGPoint(x: centre.x + (anchor.x - 0.5) / zoom, y: centre.y + (anchor.y - 0.5) / zoom)
        zoom = next
        look(at: CGPoint(x: under.x - (anchor.x - 0.5) / next, y: under.y - (anchor.y - 0.5) / next))
        if next == 1 { face = nil }
    }

    /// Move the view; it never leaves the picture.
    func look(at point: CGPoint) {
        let half = 0.5 / zoom
        centre = CGPoint(x: min(1 - half, max(half, point.x)), y: min(1 - half, max(half, point.y)))
    }

    func fit() {
        withAnimation(.spring(duration: 0.4)) { zoom = 1; centre = CGPoint(x: 0.5, y: 0.5); face = nil }
    }

    /// Jump to the next face, then back to the whole picture.
    func nextFace() {
        guard !faces.isEmpty else { return }
        let next: Int? = face.map { $0 + 1 < min(faces.count, 4) ? $0 + 1 : nil } ?? 0
        guard let next else { fit(); return }
        let box = faces[next]
        withAnimation(.spring(duration: 0.45)) {
            face = next
            zoom = min(7, max(1.6, 0.55 / max(box.height, 0.02)))   // the face takes about half the height
            look(at: CGPoint(x: box.midX, y: box.midY))
        }
    }

    // MARK: my own looks

    /// Stores the way the photo on screen is edited in Lightroom right now as a new look.
    func saveStyle(named name: String, done: @escaping (Bool) -> Void) {
        guard stage == .choosing, !savingStyle else { return }
        savingStyle = true; styleError = nil
        let id = photo
        let title = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\t", with: " ")
        Task {
            do {
                // the photo on screen first; the other photos of the session that are edited count as examples too
                let all = [id] + (session?.ids ?? []).filter { $0 != id }
                let lines = try await Bridge.send([("action", "learnstyle"), ("name", title.isEmpty ? "我的风格" : title),
                                                   ("ids", all.map(String.init).joined(separator: ","))], timeout: 600)
                let key = lines.first ?? ""
                try await loadLooks(of: id)                 // makes the picture of the new look
                for other in previews.keys where other != id { previews[other] = nil }   // they lack the new look
                if looks.contains(where: { $0.id == key }) { look = key }
                savingStyle = false
                done(true)
            } catch {
                styleError = error.localizedDescription
                savingStyle = false
                done(false)
            }
        }
    }

    func deleteStyle(_ key: String) {
        Task {
            _ = try? await Bridge.send([("action", "forgetstyle"), ("key", key)], timeout: 60)
            for id in previews.keys { previews[id]?.looks.removeAll { $0.id == key } }
            if look == key { look = "d" }
        }
    }

    // MARK: retouching, in pieces that can be paused, resumed and retried

    func retouch() {
        guard session != nil, !nothingToDo else { return }
        UserDefaults.standard.set(look, forKey: "look")
        UserDefaults.standard.set(level.rawValue, forKey: "beautyLevel")
        UserDefaults.standard.set(Array(shapes), forKey: "shapes")
        UserDefaults.standard.set(denoise, forKey: "denoise")
        UserDefaults.standard.set(best, forKey: "best")
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        run = Run(id: stamp.string(from: Date()), ids: targets, look: look, level: level.rawValue,
                  slim: false, denoise: denoise, tweak: tweakNow, shapes: shapeList, people: people.isEmpty ? nil : choiceList, best: best)
        work()
    }

    /// Carries on with `run` from wherever it stands.
    func work() {
        guard var job = run, !job.finished else { return }
        face = nil; zoom = 1; centre = CGPoint(x: 0.5, y: 0.5); pauseAsked = false; notice = nil
        caption = "正在交给 Lightroom…"
        withAnimation(.easeInOut(duration: 0.35)) { stage = .working }
        let list = { (ids: [Int]) in ids.map(String.init).joined(separator: ",") }
        // how much of the whole each step is, per photo: denoising and retouching take seconds, toning hardly any
        let wDenoise = job.denoise ? 9.0 : 0, wTone = job.look != "none" ? 1.5 : 0, wBeauty = job.level != "off" ? 9.0 : 0
        let total = max(1, Double(job.ids.count) * (wDenoise + wTone + wBeauty))
        func progress(_ j: Run) -> Double {
            (Double(j.denoised.count) * wDenoise + (j.toned ? Double(j.ids.count) * wTone : 0)
             + Double(j.done.count + j.failed.count) * (j.level != "off" ? wBeauty : 0)) / total
        }
        func keep(_ j: Run) {
            run = j
            if let data = try? JSONEncoder().encode(j) { try? data.write(to: Bridge.run, options: .atomic) }
            withAnimation(.easeOut(duration: 0.4)) { fraction = progress(j) }
        }
        fraction = progress(job)
        Task {
            do {
                try? FileManager.default.createDirectory(at: Bridge.undo, withIntermediateDirectories: true)
                if !job.saved {
                    _ = try await Bridge.send([("action", "save"), ("file", job.settingsFile.path), ("ids", list(job.ids))], timeout: 300)
                    job.saved = true; keep(job)
                }
                // how each photo looked before, for looking at the results later
                let lacking = job.ids.filter { !FileManager.default.fileExists(atPath: Bridge.before.appendingPathComponent("\($0).jpg").path) }
                for chunk in lacking.chunked(20) where !job.toned && job.done.isEmpty {
                    caption = "正在记下修图前的样子…"
                    _ = try? await Bridge.send([("action", "thumbs"), ("size", "1400"), ("dir", Bridge.before.path), ("ids", list(chunk))], timeout: 300)
                }
                @MainActor func step(_ arguments: [(String, String)], ids: [Int], weight: Double) async throws -> [String] {
                    try? FileManager.default.removeItem(at: Bridge.progress)
                    chunkBase = fraction; chunkSpan = Double(ids.count) * weight / total
                    return try await Bridge.send(arguments + [("progress", Bridge.progress.path), ("ids", list(ids))],
                                                 timeout: 240 + Double(ids.count) * 200)
                }
                if job.denoise {
                    for chunk in job.ids.filter({ !job.denoised.contains($0) }).chunked(4) {
                        if pauseAsked { return pause() }
                        let lines = (try? await step([("action", "oneclick"), ("style", "none"), ("beauty", "off"), ("denoise", "1")],
                                                     ids: chunk, weight: wDenoise)) ?? []
                        job.denoiseSwitched += Self.value("denoisedids", in: lines).split(separator: ",").compactMap { Int($0) }
                        job.denoised += chunk; keep(job)
                    }
                }
                if job.look != "none", !job.toned {
                    // all at once, so that the photos of one shoot get the same look
                    for chunk in job.ids.chunked(150) {
                        if pauseAsked { return pause() }
                        var arguments = [("action", "oneclick"), ("style", job.look), ("beauty", "off")]
                        if !job.tweak.isZero { arguments.append(("tweak", job.tweak.argument)) }
                        _ = try await step(arguments, ids: chunk, weight: wTone)
                    }
                    job.toned = true; keep(job)
                }
                if job.level != "off" {
                    for chunk in job.ids.filter({ !job.done.contains($0) && !job.failed.contains($0) }).chunked(3) {
                        if pauseAsked { return pause() }
                        let arguments = [("action", "oneclick"), ("style", "none"), ("beauty", job.level),
                                         ("bits", job.best == true ? "16" : "8")] + (job.shapes ?? (job.slim ? ["slim"] : [])).map { ($0, "1") }
                            + (job.people.map { ($0.isEmpty ? [] : [("people", $0)]) + [("peoplefile", Self.peopleFile.path)] } ?? [])
                        var made: [String: Int] = [:]
                        for attempt in 1...2 {     // a piece that fails is tried once more
                            let lines = (try? await step(arguments, ids: chunk.filter { made[String($0)] == nil }, weight: wBeauty)) ?? []
                            for pair in Self.value("created", in: lines).split(separator: ",") {
                                let ends = pair.split(separator: ":")
                                if ends.count == 2, let new = Int(ends[1]) { made[String(ends[0])] = new }
                            }
                            if made.count == chunk.count { break }
                            if attempt == 1 { caption = "有照片没成功，再试一次…" }
                        }
                        job.created.merge(made) { _, new in new }
                        job.done += chunk.filter { made[String($0)] != nil }
                        job.failed += chunk.filter { made[String($0)] == nil }
                        keep(job)
                    }
                } else {
                    job.done = job.ids
                }
                job.finished = true; keep(job)
                fraction = 1
                withAnimation(.spring(duration: 0.5)) { stage = .finished }
            } catch {
                keep(job)
                stage = .failed(error.localizedDescription + "\n已经做完的部分都在，可以点“继续”接着做。")
            }
        }
    }

    private func pause() {
        pauseAsked = false
        withAnimation(.easeInOut(duration: 0.3)) { stage = .paused }
    }

    private static func value(_ name: String, in lines: [String]) -> String {
        lines.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } ?? ""
    }

    /// Try the photos again that did not work.
    func retryFailed() {
        guard var job = run, !job.failed.isEmpty else { return }
        job.failed = []; job.finished = false
        run = job
        work()
    }

    /// Give up the rest of a run that was paused or interrupted; what is done stays.
    func stopRun() {
        guard var job = run else { return }
        job.ids = job.done; job.failed = []; job.finished = true
        run = job
        if let data = try? JSONEncoder().encode(job) { try? data.write(to: Bridge.run, options: .atomic) }
        withAnimation(.spring(duration: 0.4)) { stage = job.done.isEmpty ? (looks.isEmpty ? .waiting : .choosing) : .finished }
    }

    /// Puts the photos back as they were before the run. Lightroom offers no way to remove pictures from its catalogue
    /// by program, so the retouched pictures are marked as rejected.
    func undoRun() {
        guard var job = run, job.saved, !job.undone else { return }
        notice = "正在撤销…"
        Task {
            var arguments = [("action", "undo"), ("file", job.settingsFile.path), ("ids", job.ids.map(String.init).joined(separator: ","))]
            if !job.created.isEmpty { arguments.append(("rejects", job.created.values.map(String.init).joined(separator: ","))) }
            if !job.denoiseSwitched.isEmpty { arguments.append(("denoised", job.denoiseSwitched.map(String.init).joined(separator: ","))) }
            do {
                _ = try await Bridge.send(arguments, timeout: 300 + Double(job.denoiseSwitched.count) * 6)
                job.undone = true; job.finished = true
                run = job
                if let data = try? JSONEncoder().encode(job) { try? data.write(to: Bridge.run, options: .atomic) }
                notice = job.created.isEmpty ? "已撤销，照片回到修图前的样子。"
                    : "已撤销。调色已还原，\(job.created.count) 张美颜成片被标记为“排除”，在 Lightroom 里用 照片 → 删除排除的照片 可以一次清掉。"
            } catch {
                notice = "撤销没有完成：" + error.localizedDescription
            }
        }
    }

    // MARK: looking at the finished pictures

    func startReview() {
        guard let job = run, let first = job.done.first else { return }
        zoom = 1; centre = CGPoint(x: 0.5, y: 0.5); face = nil
        for id in job.ids where thumbs[id] == nil {
            if let image = NSImage(contentsOf: Bridge.before.appendingPathComponent("\(id).jpg")) { thumbs[id] = image }
        }
        withAnimation(.easeInOut(duration: 0.35)) { stage = .reviewing }
        review(job.done.contains(photo) ? photo : first)
    }

    private func review(_ id: Int) {
        guard let job = run, loading == nil else { return }
        zoom = 1; centre = CGPoint(x: 0.5, y: 0.5)
        photo = id
        if befores[id] == nil { befores[id] = NSImage(contentsOf: Bridge.before.appendingPathComponent("\(id).jpg")) }
        guard results[id] == nil else { return }
        let shown = job.created[String(id)] ?? id          // the retouched picture, or the photo itself when only toned
        loading = id
        Task {
            let lines = (try? await Bridge.send([("action", "thumbs"), ("size", "1400"), ("dir", Bridge.after.path),
                                                 ("ids", String(shown))], timeout: 120)) ?? []
            if let image = Self.images(lines).first?.1 { results[id] = image }
            loading = nil
        }
    }

    func backToLightroom() {
        let config = NSWorkspace.OpenConfiguration()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.LightroomClassicCC7") {
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    func again() {
        results = [:]; befores = [:]; loading = nil
        if looks.isEmpty, let session { photo = session.active }
        withAnimation(.easeInOut(duration: 0.35)) { stage = looks.isEmpty ? .waiting : .choosing }
    }

    func leaveReview() {
        loading = nil
        withAnimation(.easeInOut(duration: 0.35)) { stage = .finished }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
