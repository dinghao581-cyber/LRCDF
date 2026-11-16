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
    /// Where the look itself puts the shadows and the highlights (split toning), as points of the colour wheels:
    /// a wheel starts there, because what it sends replaces the look's value.
    var shadow = CGPoint.zero, high = CGPoint.zero
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
    var title: String { ["off": L.levelOff, "auto": L.levelAuto, "natural": L.levelNatural, "refined": L.levelRefined][rawValue]! }
    var note: String {
        ["off": L.levelOffNote, "auto": L.levelAutoNote, "natural": L.levelNaturalNote, "refined": L.levelRefinedNote][rawValue]!
    }
}

/// Small nudges on top of a look. The three rows run from -2 to 2, stepless, and are shown as -100 … +100
/// (value x 50). The colour wheels: white balance = (warm, tint), each -2 … 2 and together inside the circle;
/// shadows and highlights = a point in the unit circle, its angle the hue, its length the amount (0 … 100).
/// Lightroom's side works on a coarser grid (rows and tint in twentieths, hue and amount in fives), so what is
/// sent, and what pictures are kept under, is rounded to that; the difference to the numbers on screen cannot be seen.
struct Tweak: Equatable, Codable {
    var bright = 0.0, warm = 0.0, rich = 0.0
    var tint = 0.0                                   // + = pink (magenta), - = green
    var shadow: CGPoint?, high: CGPoint?             // x to the right, y upwards; nil = as the look has it

    init() {}
    init(from decoder: Decoder) throws {             // runs saved before the wheels have only the first three
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bright = try c.decodeIfPresent(Double.self, forKey: .bright) ?? 0
        warm = try c.decodeIfPresent(Double.self, forKey: .warm) ?? 0
        rich = try c.decodeIfPresent(Double.self, forKey: .rich) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        shadow = try c.decodeIfPresent(CGPoint.self, forKey: .shadow)
        high = try c.decodeIfPresent(CGPoint.self, forKey: .high)
    }

    /// The white-balance wheel's point: right = warmer, up = pinker.
    var balance: CGPoint {
        get { CGPoint(x: warm / 2, y: tint / 2) }
        set { warm = Double(newValue.x) * 2; tint = Double(newValue.y) * 2 }
    }
    /// Hue in degrees (red to the right, counter-clockwise) and amount 0 … 100 of a shadows / highlights point.
    static func grade(_ point: CGPoint, step: Double = 1) -> (hue: Int, amount: Int) {
        let amount = Int((min(1, Double(hypot(point.x, point.y))) * 100 / step).rounded() * step)
        guard amount > 0 else { return (0, 0) }
        var degrees = atan2(Double(point.y), Double(point.x)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return (Int((degrees / step).rounded() * step) % 360, amount)
    }

    static func point(hue: Double, amount: Double) -> CGPoint {
        let (angle, length) = (hue * .pi / 180, min(1, max(0, amount / 100)))
        return CGPoint(x: (cos(angle) * length * 100).rounded() / 100, y: (sin(angle) * length * 100).rounded() / 100)
    }

    private static func hundredths(_ value: Double) -> Int { Int((value * 20).rounded()) * 5 }
    private static func text(_ hundredths: Int) -> String { String(format: "%g", Double(hundredths) / 100) }
    private var rows: [Int] { [bright, warm, rich].map(Self.hundredths) }
    /// The wheels, as far as they are off their centres: argument name, its value, and the piece of the file name.
    private var wheels: [(name: String, value: String, piece: String)] {
        var list: [(String, String, String)] = []
        let n = Self.hundredths(tint)
        if n != 0 { list.append(("tint", Self.text(n), "_n\(n)")) }
        for (name, letter, point) in [("shadow", "s", shadow), ("high", "h", high)] {
            guard let point else { continue }
            // set to the centre = no colour there, also where the look has one (amount 0 says so)
            let g = Self.grade(point, step: 5)
            list.append((name, "\(g.hue),\(g.amount)", "_\(letter)\(g.hue)-\(g.amount)"))
        }
        return list
    }
    var isZero: Bool { rows == [0, 0, 0] && wheels.isEmpty }
    /// What is sent to Lightroom's side: tweak=0.35,-1.2,0 and, where set, tint=0.4 shadow=210,30 high=45,20.
    var arguments: [(String, String)] {
        [("tweak", rows.map(Self.text).joined(separator: ","))] + wheels.map { ($0.name, $0.value) }
    }
    /// Under this the pictures of a tweak are kept.
    var key: String { rows.map(String.init).joined(separator: ",") + wheels.map { $0.piece }.joined() }
    /// The preview Lightroom's side renders for this tweak of a look is called this (Simple.tweakName).
    func fileName(_ look: String) -> String {
        "\(look)_t" + rows.map(String.init).joined(separator: "_") + wheels.map { $0.piece }.joined()
    }
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
    case choosing
    case working
    case paused
    case finished
    case reviewing                    // looking at the finished pictures
    case failed(String)
}

/// What goes on behind the main screen after photos have been handed over, for the small progress line. Every
/// number is a count of answers that really came back from Lightroom's side.
struct Opening: Equatable {
    var first = false                 // the photo on show has its picture
    var read = 0, toRead = 0          // small pictures for the strip
    var loaded = 0, toLoad = 0        // photos with their original and the chosen look (first round of the loading)
    var checked = 0, toCheck = 0      // closed eyes, out of focus
    var made = 0, toMake = 0          // the other looks of every photo (second round)
}

@MainActor
final class Studio: ObservableObject {
    @Published var stage: Stage = .waiting
    /// How much of the window's bottom the controls of the main screen take (look tray or paged bar): the update line
    /// sits above it instead of over it.
    @Published var bottomChrome: CGFloat = 0
    /// The height of the update line while it shows: the photo makes room for it, so it never covers the picture.
    @Published var updateLine: CGFloat = 0
    /// The background work on the photos just handed over; nil once all of it is done.
    @Published var opening: Opening?
    /// The photo on show has no picture yet: the screen is there, the button is not to be pressed.
    var starting: Bool { opening?.first == false }
    /// How many looks there were last time: that many empty cards stand in until the real ones come.
    var lookGuess: Int { max(2, UserDefaults.standard.integer(forKey: "lookCount") == 0 ? 8 : UserDefaults.standard.integer(forKey: "lookCount")) }
    /// The line beside the progress bar, and how far the bar has got.
    var openingLine: (text: String, fraction: Double)? {
        guard let o = opening, stage == .choosing else { return nil }
        let text: String
        if !o.first { text = o.toRead > 0 && o.read == 0 ? L.progressReading(0, o.toRead) : L.progressFirst }
        else if o.read < o.toRead { text = L.progressReading(o.read, o.toRead) }
        else if o.loaded < o.toLoad { text = L.progressLoading(o.loaded, o.toLoad) }
        else if o.checked < o.toCheck { text = L.progressChecking(o.checked, o.toCheck) }
        else { text = L.progressLooks(o.made, o.toMake) }
        // the second round's size is only known once the first has asked every photo: until then a guess
        let more = o.loaded < o.toLoad ? o.toLoad * max(0, lookGuess - 2) : o.toMake
        let total = o.toRead + o.toLoad + o.toCheck + more
        return (text, Double(o.read + o.loaded + o.checked + o.made) / Double(max(total, 1)))
    }
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
    private var names: [String: String] = [:]             // what Lightroom's side called the tweaked previews, by key
    /// While a tweak row is being dragged: Lightroom is asked for the exact picture only once the drag has ended
    /// (one takes about ten seconds); until then the approximation (Quick) follows the knob.
    var dragging = false { didSet { if !dragging { wantPictures() } } }
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
    private var preloading = false
    private var userAt = Date.distantPast           // the user's last wish: background work keeps out of its way a moment
    private var unloadable: Set<Int> = []           // photos whose pictures could not be made: not asked again
    private var chunkBase = 0.0, chunkSpan = 0.0

    var looks: [Look] { previews[photo]?.looks ?? [] }
    /// The looks of each photo still to be made: empty cards hold their places.
    @Published var toCome: [Int: [String]] = [:]
    var looksToCome: Int { previews[photo] == nil ? lookGuess : (toCome[photo]?.count ?? 0) }
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
    var busy: Bool { starting || stage == .working || loading != nil || !making.isEmpty || culling || preloading || savingStyle }

    // MARK: pictures on the "after" side

    /// Where the look on show itself puts shadows and highlights.
    var own: (shadow: CGPoint, high: CGPoint) { (chosen?.shadow ?? .zero, chosen?.high ?? .zero) }
    private var tweakNow: Tweak { look == "none" ? Tweak() : tweak }
    private func lookKey(_ t: Tweak) -> String { "\(photo)|\(look)|\(t.key)" }
    private func beautyKey(_ t: Tweak, _ level: BeautyLevel) -> String {
        "\(photo)|\(look)|\(t.key)|\(level.rawValue)|\(shapeList.joined(separator: "+"))|\(choiceList)"
    }
    /// The look, with the tweak: Lightroom's picture when it is ready, until then an immediate approximation (Quick).
    private var base: NSImage? {
        if tweakNow.isZero { return chosen?.image }
        if let exact = pictures[lookKey(tweakNow)] { return exact }
        guard let plain = chosen?.image else { return nil }
        return Quick.picture(plain, key: "\(photo)|\(look)", tweak: tweakNow, own: own)
    }
    /// What the "after" side shows: look, tweak and beautification, as far as they are ready. While a tweaked picture
    /// is on its way, the tweak is approximated on the beautified picture of the untouched look, so the face does not
    /// jump back to unretouched.
    var after: NSImage? {
        if level == .off { return base }
        if let exact = pictures[beautyKey(tweakNow, level)] { return exact }
        if !tweakNow.isZero, let plain = pictures[beautyKey(Tweak(), level)] {
            return Quick.picture(plain, key: beautyKey(Tweak(), level), tweak: tweakNow, own: own)
        }
        return base
    }
    var beautyShown: Bool { level != .off && pictures[beautyKey(tweakNow, level)] != nil }
    var pictureExact: Bool {
        (tweakNow.isZero || pictures[lookKey(tweakNow)] != nil) && (level == .off || beautyShown)
    }

    func start() {
        #if DEBUG
        // Layout checks of the progress line without Lightroom (debug builds only, never in the app that is shipped):
        // LRCDF_PROGRESS=first|reading|loading|checking|looks shows the main screen standing at that step.
        if let step = ProcessInfo.processInfo.environment["LRCDF_PROGRESS"] {
            session = Session(time: 0, active: 1, ids: Array(1...80), name: "IMG_0001.CR2", iso: 400)
            photo = 1
            // each step as it stands while that work is under way: what comes before it is done
            var o = Opening(first: step != "first", read: 80, toRead: 80, loaded: 80, toLoad: 80, checked: 80, toCheck: 80, made: 120, toMake: 400)
            switch step {
            case "first", "reading": o.read = 13; o.loaded = 0; o.checked = 0; o.made = 0
            case "loading": o.loaded = 5; o.checked = 0; o.made = 0
            case "checking": o.checked = 24; o.made = 0
            default: break
            }
            opening = o
            stage = .choosing
            return
        }
        if let screen = ProcessInfo.processInfo.environment["LRCDF_DEMO"] { demo(screen); return }
        #endif
        if let data = try? Data(contentsOf: Bridge.run), let last = try? JSONDecoder().decode(Run.self, from: data) { run = last }
        // The preview folder is kept below 3 GB (Cache.swift). Not when photos have just been handed over - Lightroom
        // starts the app with them: then it is done once their first round is loaded, when their folders are known.
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if opening == nil { await PreviewCache.trim(keep: Set(previews.values.map(\.folder))) }
        }
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
        guard !starting, stage != .working, stage != .paused,
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
        previews = [:]; toCome = [:]; unloadable = []; thumbs = [:]; pictures = [:]; Quick.forget(); making = []; flags = [:]; face = nil; loading = nil
        people = []; choices = [:]; everyone = []
        zoom = 1; centre = CGPoint(x: 0.5, y: 0.5); tweak = Tweak(); skipFlagged = false; notice = nil
        photo = incoming.active
        // Straight to the main screen (user: as on the iPad, do not make me wait in front of nothing): the photo
        // on show first - its small picture, then the original and the look - then the strip, the other looks and
        // the selection help, all behind the screen, told by the progress line.
        let strip = incoming.ids.count > 1 ? Array(incoming.ids.prefix(120)) : []
        opening = Opening(toRead: strip.count, toLoad: incoming.ids.count, toCheck: incoming.ids.count)
        withAnimation(.easeInOut(duration: 0.5)) { stage = .choosing }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await loadThumbs([incoming.active], incoming, counted: !strip.isEmpty)
            do {
                try await loadLooks(of: incoming.active)
            } catch {
                guard session == incoming else { return }
                opening = nil
                stage = .failed(error.localizedDescription)
                return
            }
            guard session == incoming else { return }
            opening?.first = true
            wantPictures()
            await loadThumbs(strip.filter { $0 != incoming.active }, incoming, counted: true)
            await preload(incoming)
            if session == incoming { withAnimation(.easeInOut(duration: 0.4)) { opening = nil } }
        }
    }

    /// Every photo handed over is loaded without being clicked (user: "as soon as photos come in, start loading all of
    /// them"). One request at a time, the next only when it is back, and only while the user asks for nothing: what they
    /// do always comes first and waits at most for the one request under way. In this order:
    ///   - the other looks of the photo on show (whichever photo that is by then)
    ///   - every photo's original and the chosen look, from the one on show onwards, so that any photo clicked is there
    ///   - closed eyes and focus, six photos at a time
    ///   - the other looks of every photo
    /// Stops for good when retouching starts or other photos are handed over; what is cached is skipped by Lightroom's side.
    private func preload(_ incoming: Session) async {
        preloading = true
        defer { if session == incoming { preloading = false } }
        let ids = incoming.ids
        var unchecked = ids
        var firstCull = true
        var trimmed = false
        while session == incoming, stage == .choosing {
            // keep out of the user's way: something of theirs under way, or asked for a moment ago
            if loading != nil || !making.isEmpty || dragging || savingStyle || Date().timeIntervalSince(userAt) < 1.2 {
                try? await Task.sleep(nanoseconds: 300_000_000); continue
            }
            let here = ids.firstIndex(of: photo) ?? 0
            let around = Array(ids[here...] + ids[..<here])
            if let name = nextLook(of: photo) {
                await makeLook(name, of: photo, incoming)
            } else if let id = around.first(where: { previews[$0] == nil && !unloadable.contains($0) }) {
                await firstRound(id, incoming)
            } else if !trimmed {
                // every photo of this batch has its folder by now: older batches' folders can go if there are too many
                trimmed = true
                await PreviewCache.trim(keep: Set(previews.values.map(\.folder)))
                continue
            } else if !unchecked.isEmpty {
                let chunk = Array(unchecked.prefix(6)); unchecked.removeFirst(chunk.count)
                await cull(chunk, fresh: firstCull, incoming); firstCull = false
            } else if let id = around.first(where: { nextLook(of: $0) != nil }), let name = nextLook(of: id) {
                await makeLook(name, of: id, incoming)
            } else {
                break
            }
            refreshCounts(incoming)
        }
    }

    /// The look of a photo to make next: the one chosen first (it is what a click on the photo shows).
    private func nextLook(of id: Int) -> String? {
        guard let rest = toCome[id], !rest.isEmpty else { return nil }
        return rest.contains(look) ? look : rest.first
    }

    private func refreshCounts(_ incoming: Session) {
        guard session == incoming, opening != nil else { return }
        let ids = incoming.ids
        opening?.loaded = ids.filter { previews[$0] != nil || unloadable.contains($0) }.count
        let left = ids.reduce(0) { $0 + (toCome[$1]?.count ?? 0) }
        let made = ids.reduce(0) { $0 + max(0, (previews[$1]?.looks.count ?? 0) - 2) }     // beyond the original and the first look
        opening?.made = made; opening?.toMake = made + left
    }

    private func firstRound(_ id: Int, _ incoming: Session) async {
        let wanted = look == "none" ? "d" : look
        guard let (found, folder, missing) = try? await askLooks(of: id, only: "none,\(wanted)"), session == incoming else {
            unloadable.insert(id); return
        }
        guard let folder, found.contains(where: { $0.id == "none" }), found.count > 1 else { unloadable.insert(id); return }
        if previews[id] == nil { previews[id] = PhotoPreview(looks: found, folder: folder, faces: readFaces(folder)) }
        toCome[id] = missing
    }

    private func makeLook(_ name: String, of id: Int, _ incoming: Session) async {
        let more = try? await askLooks(of: id, only: name)
        guard session == incoming else { return }
        toCome[id]?.removeAll { $0 == name }             // made, or failed: not asked again
        if let more, previews[id] != nil { withAnimation(.easeInOut(duration: 0.3)) { previews[id]?.looks = more.0 } }
    }

    private func cull(_ chunk: [Int], fresh: Bool, _ incoming: Session) async {
        culling = true
        defer { culling = false }
        let lines = (try? await patiently([("action", "cull"), ("size", "1400"), ("dir", Bridge.before.path), ("fresh", fresh ? "1" : "0"),
                                           ("ids", chunk.map(String.init).joined(separator: ","))], timeout: 240)) ?? []
        guard session == incoming else { return }
        readPeople()
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 2, let id = Int(parts[0]) { flags[id] = parts[1].split(separator: ",").map(String.init) }
        }
        opening?.checked += chunk.count                  // also when the answer failed: it is not asked again
    }

    /// Small pictures of the photos that were handed over, for the strip on the left: a few at a time, so that the
    /// strip fills as they come and the count on the progress line is a real one.
    private func loadThumbs(_ ids: [Int], _ incoming: Session, counted: Bool) async {
        var rest = ids
        var stopped = false
        while !rest.isEmpty, session == incoming {
            let chunk = Array(rest.prefix(12)); rest.removeFirst(chunk.count)
            guard let lines = try? await patiently([("action", "thumbs"), ("size", "240"), ("dir", Bridge.thumbs.path),
                                                    ("ids", chunk.map(String.init).joined(separator: ","))], timeout: 300) else { stopped = true; break }
            guard session == incoming else { return }
            for (id, image) in Self.images(lines) { thumbs[id] = image }
            if counted { opening?.read += chunk.count }
        }
        // whatever could not be read is not waited for
        if session == incoming, counted, stopped, let o = opening { opening?.toRead = o.read }
    }

    /// A command sent right after a long one. The plug-in cannot write its sign of life while it works, so for a
    /// moment after a long answer Lightroom looks closed although it is not: that is waited out, a few seconds at most.
    private func patiently(_ arguments: [(String, String)], timeout: TimeInterval) async throws -> [String] {
        for _ in 0..<8 {
            do { return try await Bridge.send(arguments, timeout: timeout) }
            catch Bridge.Failure.lightroomAway { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return try await Bridge.send(arguments, timeout: timeout)
    }

    private static func images(_ lines: [String]) -> [(Int, NSImage)] {
        lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let id = Int(parts[0]), let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])),
                  let image = NSImage(data: data) else { return nil }
            return (id, image)
        }
    }

    /// The looks of a photo. Lightroom renders them one after the other (about five seconds each), so the look on
    /// screen comes first and the photo is shown with it; the other cards fill in one by one behind whatever the user
    /// asks for meanwhile.
    private func loadLooks(of id: Int) async throws {
        let wanted = look == "none" ? "d" : look
        let (found, folder, missing) = try await askLooks(of: id, only: "none,\(wanted)")
        guard let folder, found.contains(where: { $0.id == "none" }), found.count > 1 else {
            throw Bridge.Failure.refused(L.noPreview)
        }
        if !found.contains(where: { $0.id == look }) { look = found.first(where: { $0.id != "none" })?.id ?? "d" }
        previews[id] = PhotoPreview(looks: found, folder: folder, faces: readFaces(folder))
        toCome[id] = missing                              // made in the background (preload), this photo's first
        UserDefaults.standard.set(found.count + missing.count, forKey: "lookCount")
        if let incoming = session { refreshCounts(incoming) }
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
            var look = Look(id: parts[0], title: parts[2], note: parts[3], image: image)
            if parts.count >= 5, parts[4].hasPrefix("wheels=") {      // shadow hue, amount, highlight hue, amount
                let v = parts[4].dropFirst(7).split(separator: ",").compactMap { Double($0) }
                if v.count == 4 { look.shadow = Tweak.point(hue: v[0], amount: v[1]); look.high = Tweak.point(hue: v[2], amount: v[3]) }
            }
            found.append(look)
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
        userAt = Date()
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
        userAt = Date()
        wish += 1
        let mine = wish
        guard !dragging, stage == .choosing, previews[photo] != nil, chosen != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard mine == wish, !dragging, stage == .choosing, let preview = previews[photo] else { return }
            let (id, style, t, lvl, shaped, own, ownArguments) = (photo, look, tweakNow, level, shapeList, choiceList, choiceArguments)
            var name = style
            if !t.isZero {
                let key = lookKey(t)
                name = t.fileName(style)
                if pictures[key] == nil {
                    guard !making.contains(key) else { return }
                    making.insert(key)
                    let lines = (try? await Bridge.send([("action", "tweakpreview"), ("dir", preview.folder.path), ("look", style)] + t.arguments
                                                        + [("size", "2600"), ("ids", String(id))], timeout: 120)) ?? []
                    making.remove(key)
                    guard let parts = lines.first?.components(separatedBy: "\t"), parts.count >= 2,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let image = NSImage(data: data) else { return }
                    names[key] = parts[0]
                    withAnimation(.easeInOut(duration: 0.3)) { pictures[key] = image }
                }
                name = names[key] ?? name                  // as Lightroom's side called it
            }
            guard lvl != .off else { return }
            let keys = [BeautyLevel.auto, .natural, .refined].map { ($0, "\(id)|\(style)|\(t.key)|\($0.rawValue)|\(shaped.joined(separator: "+"))|\(own)") }
            guard let wanted = keys.first(where: { $0.0 == lvl })?.1, pictures[wanted] == nil, !making.contains(wanted) else { return }
            // The level on show first, alone: the three together take about 15 s, 自然 or 精致 alone about 4 s,
            // 自动 alone about 12 s (it tries the levels to choose). The other two follow while nothing else is asked for.
            for batch in [keys.filter { $0.0 == lvl }, keys.filter { $0.0 != lvl }] {
                let todo = batch.filter { pictures[$0.1] == nil && !making.contains($0.1) }
                guard !todo.isEmpty else { continue }
                todo.forEach { making.insert($0.1) }
                let lines = (try? await Bridge.send([("action", "beautypreview"), ("dir", preview.folder.path), ("look", name),
                                                     ("levels", todo.map { $0.0.rawValue }.joined(separator: ","))]
                                                    + shaped.map { ($0, "1") } + ownArguments, timeout: 240)) ?? []
                for line in lines {
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2, let pair = todo.first(where: { $0.0.rawValue == parts[0] }),
                          let data = try? Data(contentsOf: URL(fileURLWithPath: parts[1])), let image = NSImage(data: data) else { continue }
                    withAnimation(.easeInOut(duration: 0.35)) { pictures[pair.1] = image }
                }
                todo.forEach { making.remove($0.1) }
                if previews[id]?.faces.isEmpty == true { previews[id]?.faces = readFaces(preview.folder) }
                guard mine == wish else { return }           // something else is wanted by now: that comes first
            }
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
                let lines = try await Bridge.send([("action", "learnstyle"), ("name", title.isEmpty ? L.defaultStyleName : title),
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
        guard session != nil, !nothingToDo, chosen != nil else { return }
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
        caption = L.handingOver
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
                    caption = L.rememberingBefore
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
                        if !job.tweak.isZero { arguments += job.tweak.arguments }
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
                            if attempt == 1 { caption = L.retrying }
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
                stage = .failed(L.failedKeep(error.localizedDescription))
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
        notice = L.undoing
        Task {
            var arguments = [("action", "undo"), ("file", job.settingsFile.path), ("ids", job.ids.map(String.init).joined(separator: ","))]
            if !job.created.isEmpty { arguments.append(("rejects", job.created.values.map(String.init).joined(separator: ","))) }
            if !job.denoiseSwitched.isEmpty { arguments.append(("denoised", job.denoiseSwitched.map(String.init).joined(separator: ","))) }
            do {
                _ = try await Bridge.send(arguments, timeout: 300 + Double(job.denoiseSwitched.count) * 6)
                job.undone = true; job.finished = true
                run = job
                if let data = try? JSONEncoder().encode(job) { try? data.write(to: Bridge.run, options: .atomic) }
                notice = job.created.isEmpty ? L.undoneNote
                    : L.undoneRejects(job.created.count)
            } catch {
                notice = L.undoFailed(error.localizedDescription)
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

#if DEBUG
/// Reference screenshots for the Windows and iPad apps without Lightroom (debug builds only): the eight outdoor test
/// photos as their pictures already lie in the preview cache. LRCDF_DEMO=closed|opening|main|tweak|working|paused|
/// finished|review|update. Nothing is sent to Lightroom: the ticker that reads the session file is not started.
extension Studio {
    func demo(_ screen: String) {
        Bridge.demo = true
        if screen == "waiting" { lightroomOpen = true; return }
        if screen.hasPrefix("failed") {
            stage = .failed(screen == "failed_away" ? L.lightroomAway : L.noAnswer); return
        }
        if screen == "closed" { lightroomOpen = false; return }     // the first screen as it is with Lightroom not running
        let ids = [50227, 50393, 50561, 50727, 50893, 51061, 51227, 51393]
        let folders = ["8839BFAD-7B09-458D-8BE3-02B928B9B0D8", "539992F2-1592-4B8F-8774-3C1AC50E69AB", "BF3DBA21-1FC3-4761-998A-085B1C78DC77",
                       "9CC8483D-0816-4E15-97E8-84F711EDD161", "B3D7C13B-B31B-47AA-AD13-95C851D143A0", "D8164A30-6714-45A4-B249-267A5483448F",
                       "0B0E5A9D-9ADD-488A-97AC-3BB4045F5B27", "E2E61521-92A2-4A02-8F89-588BC122103A"]
        let cards = [("none", "原片", "不调色"), ("d", "自然清透", "白里透粉，明亮柔和"), ("a", "明亮通透", "干净偏冷，肤色白皙"),
                     ("e", "韩系", "奶白低饱和，柔和"), ("b", "柔和暖调", "温暖，低对比"), ("c", "鲜艳浓郁", "色彩饱满"), ("f", "港风", "浓郁暖调，胶片颗粒")]
        session = Session(time: 0, active: 50727, ids: ids, name: "1557_0.CR2", iso: screen == "noisy" ? 3200 : 400)
        photo = 50727
        look = "d"
        for id in ids {
            if let image = NSImage(contentsOf: Bridge.thumbs.appendingPathComponent("\(id).jpg")) { thumbs[id] = image }
        }
        flags = [50393: ["eyes"], 51061: ["blur"]]
        stage = .choosing
        if screen == "opening" {
            opening = Opening(first: false, read: 1, toRead: 8, loaded: 0, toLoad: 8, checked: 0, toCheck: 8)
            return
        }
        if screen == "loading" {           // the photo on show is there, the rest still coming: some thumbnails not yet in
            for id in ids.suffix(3) { thumbs[id] = nil }
            opening = Opening(first: true, read: 5, toRead: 8, loaded: 1, toLoad: 8, checked: 0, toCheck: 8)
        }
        for (id, name) in zip(ids, folders) where screen != "loading" || id == 50727 {
            let folder = Bridge.previews.appendingPathComponent(name + "_2600", isDirectory: true)
            var looks = cards.compactMap { c -> Look? in
                NSImage(contentsOf: folder.appendingPathComponent(c.0 + ".jpg")).map { Look(id: c.0, title: c.1, note: c.2, image: $0) }
            }
            // 港风 brings its own split toning: the wheels start there
            if let k = looks.firstIndex(where: { $0.id == "f" }) {
                looks[k].shadow = Tweak.point(hue: 195, amount: 35); looks[k].high = Tweak.point(hue: 45, amount: 30)
            }
            if screen == "mine", let image = NSImage(contentsOf: folder.appendingPathComponent("b.jpg")) {
                looks.append(Look(id: "u1", title: "我的日系", note: "我的风格 · 学自 6 张照片", image: image))
            }
            previews[id] = PhotoPreview(looks: looks, folder: folder, faces: readFaces(folder))
        }
        let folder = previews[50727]!.folder
        for level in [BeautyLevel.auto, .natural, .refined] {
            if let image = NSImage(contentsOf: folder.appendingPathComponent("d_\(level.rawValue).jpg")) { pictures[beautyKey(Tweak(), level)] = image }
        }
        if screen == "tweak" { tweak.bright = 0.6; tweak.rich = -0.3; tweak.balance = CGPoint(x: 0.3, y: -0.15) }
        if screen == "own" { look = "f" }                                   // a look with its own colour: wheels start off-centre
        if screen == "ownmoved" { look = "f"; tweak.shadow = Tweak.point(hue: 240, amount: 55) }
        if screen == "mine" { look = "u1" }
        if screen == "saving" { savingStyle = true }                       // the save-style sheet while it learns
        if screen == "zoomed" { zoom = 2.6; centre = CGPoint(x: 0.5, y: 0.32) }
        if screen == "people" {
            people = (1...5).compactMap { n in
                NSImage(contentsOf: Bridge.before.appendingPathComponent("person_\(n).jpg")).map { Person(id: n, image: $0, photos: 6 - n) }
            }
            choices = [1: "follow", 2: "light", 3: "refined", 4: "off", 5: "follow"]
        }
        var job = Run(id: "demo", ids: ids, look: "d", level: "auto", slim: false, denoise: false, tweak: Tweak())
        switch screen {
        case "working", "working25", "working60":
            let f = screen == "working25" ? 0.25 : screen == "working60" ? 0.6 : 0.42
            job.done = Array(ids.prefix(Int(f * 8))); run = job; fraction = f; caption = "正在美颜第 \(Int(f * 8) + 1) 张"; stage = .working
        case "paused":
            job.done = Array(ids.prefix(3)); run = job; stage = .paused
        case "finished_ok":
            job.done = ids; job.finished = true
            for id in job.done { job.created[String(id)] = id + 100000 }
            run = job; stage = .finished
        case "finished_undone":
            job.done = ids; job.finished = true; job.undone = true
            run = job; notice = L.undoneRejects(ids.count); stage = .finished
        case "finished":
            job.done = Array(ids.prefix(6)); job.failed = Array(ids.suffix(2)); job.finished = true
            for id in job.done { job.created[String(id)] = id + 100000 }
            run = job; stage = .finished
        case "review":
            job.done = Array(ids.prefix(6)); job.finished = true; run = job
            for (id, name) in zip(ids, folders) {
                let f = Bridge.previews.appendingPathComponent(name + "_2600", isDirectory: true)
                befores[id] = NSImage(contentsOf: f.appendingPathComponent("none.jpg"))
                results[id] = NSImage(contentsOf: f.appendingPathComponent("d_auto.jpg")) ?? NSImage(contentsOf: f.appendingPathComponent("d.jpg"))
            }
            stage = .reviewing
        case "update", "update_downloading", "update_ready", "update_failed":
            let state: Updater.State = screen == "update_downloading" ? .downloading(version: "1.4.0", done: 0.46)
                : screen == "update_ready" ? .ready(version: "1.4.0")
                : screen == "update_failed" ? .failed(L.updateUnreachable) : .available(version: "1.4.0", bytes: 48_300_000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Updater.shared.state = state }
        default: break
        }
    }
}
#endif
