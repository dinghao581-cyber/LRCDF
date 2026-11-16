import CoreImage
import Foundation
import Photos
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One imported photo: its copy in the app's folder, a preview-size decode and what the model said about it.
final class Photo: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    var preview: CIImage?
    var grades: [Int: Grade] = [:]
    var thumb: CGImage?
    var faces: [Face] = []
    var edits: [CIImage?] = []      // blemish model on the preview
    var memos: [String: BeautyMemo] = [:]   // retouching measurements, per look
    var fullWidth: CGFloat = 0
    var cards: [String: CGImage] = [:]     // one small picture per look
    var cardsMask: SkinOnly.Mask?   // the skin mask the cards were made with: made again when the mask arrives
    var original: CGImage?          // the preview as it came, for the left of the divider
    var people: People?             // bodies and the people mask (found when body shaping is first asked for)
    var plans: [String: ShapePlan?] = [:]    // 塑形 plans per set of switches
    var skinPlans: [String: SkinPlan] = [:]  // 保留本色, per look (made once faces are known)
    var skinMask: SkinOnly.Mask?    // 橙黄只落皮肤 (SkinOnly.on only): where the skin is; nil = no skin, the look as made
    var shown: CGImage?             // the finished preview, made in the background (kept only while the settings match)
    var shownKey: String?
    var analysed = false            // faces found and the blemish model run (the picture shows before that)
    var iso: Int?                   // from the file's EXIF (Denoise.iso); nil = unknown
    var isRAW = false               // from the file's format (Denoise.isRAW): RAW keeps the decoder's own denoise
    var denoised: CIImage?          // 降噪: the preview denoised at full resolution then reduced, as a bitmap (capped)
    /// The 降噪 switch does something to this photo: not RAW, and ISO 1600 or more (or unknown: a mild amount).
    var denoiseApplies: Bool { !isRAW && (iso.map { $0 >= 1600 } ?? true) }
    var loading = false             // decode or analysis under way (main actor): never two at once for one photo
    var looksReady = false          // round 2 of the background loading: every look's skin plan and the look cards
    init(url: URL) { self.url = url }
}

@MainActor
final class Studio: ObservableObject {
    enum Stage: Equatable { case empty, working(String), ready, exporting(Int, Int), done(Int) }

    @Published var photos: [Photo] = []
    @Published var current: UUID?
    @Published var look: String = "a" {
        didSet { if look != oldValue { tweak = tweak.starting(at: Look.all.first { $0.id == look }) } }
    }
    @Published var tweak = Tweak()
    @Published var beauty: BeautyLevel = .auto
    @Published var shapes = ShapeSet()                // 塑形 / 匀光 switches
    /// 降噪 (Denoise.swift, Codex): one switch for the batch, as on the Mac; off by default; each photo decides by its
    /// own type and ISO (`Photo.denoiseApplies`). Remembered between sessions.
    @Published var denoise = UserDefaults.standard.bool(forKey: "denoise") {
        didSet { UserDefaults.standard.set(denoise, forKey: "denoise") }
    }
    @Published var beautyAmount: Double = 1          // strength slider: 0.3 … 1.6, 1 = the level as set
    @Published var faceCards: [BeautyLevel: CGImage] = [:]   // the main face at each level
    @Published var stage: Stage = .empty
    @Published var showOriginal = false
    @Published var picture: CGImage?            // what is on screen
    @Published var originalPicture: CGImage?    // the same photo untouched (left of the divider)
    @Published var cards: [String: CGImage] = [:] // one small picture per look, of the current photo
    @Published var message: String?
    @Published var progress: (done: Int, total: Int, what: String)?   // background loading (the thin bar): real photo counts

    /// What a finished preview depends on.
    private var settingsKey: String { "\(look)|\(tweak.key)|\(beauty.rawValue)|\(beautyAmount)|\(shapes.key)|\(denoise)" }

    init() {
        // copies left by an earlier session (imports, exports that never reached the album) go at once
        for name in ["imports", "exports"] {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            for u in (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: u) }
        }
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
        #endif
    }

    private let engine = Engine.shared
    private let previewSide: CGFloat = 2400
    private var rendering = false, again = false     // one render at a time; changes meanwhile ask for one more

    var currentPhoto: Photo? { photos.first { $0.id == current } }
    /// Reading, retouching or saving photos: prompts wait.
    var busy: Bool { switch stage { case .working, .exporting: true; default: false } }

    nonisolated static let folder: URL = {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    // MARK: import

    func add(_ urls: [URL], show: Bool = false) {
        guard !urls.isEmpty else { return }
        let fresh = urls.map { Photo(url: $0) }
        photos.append(contentsOf: fresh)
        if current == nil || show { current = fresh.last?.id }       // show: a photo just taken (联机拍摄) is put on screen
        if currentPhoto?.preview == nil { stage = .working("正在读取照片…") }
        kick()
    }

    // MARK: background loading (导入即加载; user 2026-11-16: "只要导入，就会默认开始加载所有导入的照片")
    //
    // One loader, one step at a time, always picking the most urgent step left:
    //  - the photo on screen first (decode + tone model, then faces and the blemish model), whatever else is going on;
    //  - round 1, the others in order from the one on screen onwards: decode, analysis, the finished preview of the
    //    chosen look (so any photo tapped shows at once);
    //  - round 2 once round 1 is done for all: every look's skin plan and the small look pictures.
    // Background steps wait while the photo on screen is being drawn, while exporting, for 20 s after a memory warning
    // and while the device is hot (thermal state serious or worse). Kept pictures are capped, tighter on 8 GB iPads.
    private var loader: Task<Void, Never>?
    private var quietUntil = Date.distantPast        // memory warning: background waits until then
    private var warned = false                       // after a memory warning: half the caps, no cards in the background
    nonisolated static let roomy: Bool = {      // more than 8 GB (TESTHOOKS: LRCDF_8GB=1 acts as an 8 GB iPad)
        #if TESTHOOKS
        if ProcessInfo.processInfo.environment["LRCDF_8GB"] == "1" { return false }
        #endif
        return ProcessInfo.processInfo.physicalMemory > 9_000_000_000
    }()
    nonisolated static let shownCap = roomy ? 12 : 6         // finished previews kept (2400 px, ~15 MB each)
    nonisolated static let originalCap = roomy ? 16 : 8     // untouched previews kept (the divider's left side)
    nonisolated static let cardsCap = roomy ? 40 : 16        // photos whose look cards are kept (~3 MB each)

    /// Start the loader if it is not running (imports, a photo tapped, settings changed, after an export).
    func kick() {
        guard loader == nil else { return }
        loader = Task { @MainActor in
            while let work = nextStep() { await work() }
            loader = nil
            // every photo of an import failed to open: not stuck on "正在读取照片…"
            if case .working = stage { stage = photos.isEmpty ? .empty : .ready }
            updateProgress()
        }
    }

    /// The photos from the one on screen onwards, then from the start.
    private var inOrder: [Photo] {
        guard let i = photos.firstIndex(where: { $0.id == current }) else { return photos }
        return Array(photos[i...] + photos[..<i])
    }
    private func round1Done(_ p: Photo) -> Bool {
        p.preview != nil && p.analysed && (p.id == current || p.shownKey == settingsKey || !keepsShown(p))
    }
    /// Within the cap of kept pictures: the photos nearest the one on screen.
    private func near(_ p: Photo, _ fullCap: Int) -> Bool {
        let cap = warned ? fullCap / 2 : fullCap
        guard let c = photos.firstIndex(where: { $0.id == current }), let i = photos.firstIndex(where: { $0.id == p.id }) else { return true }
        let d = abs(i - c)
        return photos.indices.map { abs($0 - c) }.filter { $0 < d }.count < cap
    }
    private func keepsShown(_ p: Photo) -> Bool { near(p, Self.shownCap) }

    /// The next thing to do, or nil when all is loaded. The step waits for its turn itself.
    private func nextStep() -> (() async -> Void)? {
        updateProgress()
        if let p = currentPhoto, p.preview == nil || !p.analysed { return { await self.load(p) } }
        let order = inOrder.filter { $0.id != current }
        for p in order where !round1Done(p) {
            return {
                await self.yieldToForeground()
                guard self.photos.contains(where: { $0 === p }) else { return }      // cleared meanwhile
                if p.preview == nil || !p.analysed { await self.load(p, oneStep: true) }
                else { await self.prerender(p) }
            }
        }
        for p in inOrder where !p.looksReady && p.preview != nil {
            return {
                await self.yieldToForeground()
                guard self.photos.contains(where: { $0 === p }) else { return }
                await self.prepareLooks(p)
            }
        }
        return nil
    }

    /// Decode (and analyse) one photo; a caller finding it under way waits for that instead of doing it twice.
    /// `oneStep`: the background does one of the two per turn, so a tapped photo gets in between.
    private func load(_ p: Photo, oneStep: Bool = false) async {
        while p.loading { try? await Task.sleep(nanoseconds: 50_000_000) }
        if p.preview == nil {
            p.loading = true; await prepare(p); p.loading = false
            if oneStep { return }
        }
        if !p.analysed, p.preview != nil { p.loading = true; await analyse(p); p.loading = false }
    }

    /// Background work waits for the foreground: the photo on screen being drawn, an export, a memory warning, heat.
    private func yieldToForeground() async {
        while rendering || { if case .exporting = stage { return true }; return false }() || Date() < quietUntil
                || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            if currentPhoto.map({ $0.preview == nil || !$0.analysed }) == true { return }      // the photo on screen needs the loader
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Round 2 for one photo: the skin plan of every look and the look cards (within the cap), then the caps applied.
    private func prepareLooks(_ p: Photo) async {
        guard let img = p.preview else { p.looksReady = true; return }
        let engine = self.engine, keepCards = !warned && near(p, Self.cardsCap) && (p.cards.isEmpty || p.cardsMask !== p.skinMask)
        let mask = p.skinMask, analysed = p.analysed
        let cards: [String: CGImage]? = await Engine.bigStack {
            if analysed { for l in Look.all where l.style != nil { _ = Studio.skinPlan(p, l, engine: engine) } }
            guard keepCards else { return nil }
            return Studio.lookCards(img, p, mask: mask, engine: engine)
        }
        if let cards { p.cards = cards; p.cardsMask = mask; if p.id == current { self.cards = cards } }
        p.looksReady = analysed
        trim()
    }

    /// Kept pictures beyond the caps go (furthest from the photo on screen first); they are made again when needed.
    private func trim() {
        for p in photos where p.id != current {
            if p.shown != nil, !near(p, Self.shownCap) { p.shown = nil; p.shownKey = nil }
            if p.original != nil, !near(p, Self.originalCap) { p.original = nil }
            if p.denoised != nil, !near(p, Self.shownCap) { Studio.planLock.lock(); p.denoised = nil; Studio.planLock.unlock() }
            if !p.cards.isEmpty, !near(p, Self.cardsCap) { p.cards = [:]; p.cardsMask = nil; p.looksReady = false }
        }
    }

    /// iOS warned about memory: background results go, background work rests for 20 s.
    func memoryWarning() {
        quietUntil = Date().addingTimeInterval(20); warned = true
        Studio.planLock.lock()
        for p in photos where p.id != current { p.shown = nil; p.shownKey = nil; p.original = nil; p.cards = [:]; p.cardsMask = nil; p.looksReady = false; p.denoised = nil }
        Studio.planLock.unlock()
        engine.context.clearCaches(); Beauty.shared.context.clearCaches()
    }

    private func updateProgress() {
        let n = photos.count
        let one = photos.filter(round1Done).count, two = photos.filter { $0.looksReady || !near($0, Self.cardsCap) }.count
        if n == 0 { progress = nil }
        else if one < n { progress = (one, n, "正在加载照片 \(one) / \(n)") }
        else if two < n, loader != nil { progress = (two, n, "正在准备风格 \(two) / \(n)") }
        else { progress = nil }
    }

    /// One small picture per look of a photo (360 px).
    nonisolated static func lookCards(_ img: CIImage, _ p: Photo, mask: SkinOnly.Mask?, engine: Engine) -> [String: CGImage] {
        let s = 360 / max(img.extent.width, img.extent.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        var cards: [String: CGImage] = [:]
        for l in Look.all {
            var t = Tweak(extra: l.extra); t.skinMask = mask
            if let c = engine.cgImage(engine.render(small, grade: l.style.flatMap { p.grades[$0] }, tweak: t)) { cards[l.id] = c }
        }
        return cards
    }

    /// The finished preview of a photo that is not on screen, with the settings as they are now.
    private func prerender(_ p: Photo) async {
        guard p.id != current, let img = p.preview, p.analysed else { return }
        let key = settingsKey, engine = self.engine, chosen = Look.all.first { $0.id == look }
        var tweak = self.tweak; tweak.extra = chosen?.extra
        let level = beauty, amount = Float(beautyAmount), set = shapes
        let memo = p.memos[look] ?? BeautyMemo(); p.memos[look] = memo
        let grade = chosen?.style.flatMap { p.grades[$0] }
        let dn = denoise
        let made = await Engine.bigStack { () -> CGImage? in
            var tweak = tweak; tweak.skin = Studio.skinPlan(p, chosen, engine: engine); tweak.skinMask = p.skinMask
            return engine.cgImage(engine.render(Studio.source(p, denoise: dn, engine: engine) ?? img, grade: grade, tweak: tweak, beauty: BeautyJob(faces: p.faces, edits: p.edits, level: level, amount: amount, memo: memo, fullWidth: p.fullWidth,
                                                                                         shape: Studio.shapePlan(p, set, men: level == .men), evenLight: set.light)))
        }
        if key == settingsKey { p.shown = made; p.shownKey = key } else { p.shownKey = nil }
    }

    /// Settings changed: previews made for the old ones are let go at once (memory), the photo on screen is redrawn.
    func settingsChanged() {
        let key = settingsKey
        for p in photos where p.id != current && p.shownKey != key { p.shown = nil; p.shownKey = nil }
        refresh()
        kick()          // round 1 makes the other photos' previews again with the new settings
    }

    /// Start again with no photos: everything imported and every preview is deleted.
    func clear() {
        for p in photos where p.url.path.hasPrefix(Self.folder.path) { try? FileManager.default.removeItem(at: p.url) }
        photos = []; current = nil; picture = nil; originalPicture = nil; cards = [:]; progress = nil; stage = .empty
        loader?.cancel(); loader = nil      // its step in progress finds its photo gone and stops
        engine.context.clearCaches()
    }

    /// Decode at preview size, ask the tone model once (all styles), make a thumbnail. Off the main thread.
    private func prepare(_ p: Photo) async {
        let engine = self.engine, side = previewSide
        let ok: Bool = await Engine.bigStack {
            Engine.lap("prepare start")
            guard let img = try? engine.decode(p.url, maxSide: side) else { return false }
            p.iso = Denoise.iso(p.url); p.isRAW = Denoise.isRAW(p.url)      // metadata only: no pixels decoded
            p.preview = img
            p.original = engine.cgImage(img)
            Engine.lap("decode")
            p.grades = (try? engine.grades(for: img)) ?? [:]
            Engine.lap("tone model")
            p.fullWidth = engine.fullWidth(p.url) ?? img.extent.width
            let s = 220 / max(img.extent.width, img.extent.height)
            p.thumb = engine.cgImage(img.transformed(by: CGAffineTransform(scaleX: s, y: s)))
            Engine.lap("thumb")
            return true
        }
        if !ok {
            message = "有一张照片打不开：\(p.url.lastPathComponent)"
            photos.removeAll { $0.id == p.id }
            if current == p.id { current = photos.first?.id }
        }
        if p.id == current {
            if case .working = stage { stage = .ready }
            refresh()
        }
        objectWillChange.send()
    }

    /// Faces and the blemish model; the picture is redrawn with retouching when it is on screen.
    private func analyse(_ p: Photo) async {
        guard let img = p.preview, !p.analysed else { return }
        await Engine.bigStack {
            p.faces = Beauty.shared.faces(in: img)
            Engine.lap("faces")
            p.edits = Beauty.shared.edits(img, faces: p.faces, fullWidth: p.fullWidth)
            Engine.lap("blemish model")
            if SkinOnly.on { p.skinMask = SkinOnly.mask(img, context: Engine.shared.context); Engine.lap("skin mask") }
            p.analysed = true
        }
        if p.id == current { refresh() }
        objectWillChange.send()
    }

    func select(_ id: UUID) {
        current = id
        if let p = currentPhoto, let ready = p.shown, p.shownKey == settingsKey { picture = ready; originalPicture = p.original; cards = p.cards }
        refresh()
        // a photo not loaded yet is loaded now, beside whatever the background is doing; the others continue from it
        if let p = currentPhoto, p.preview == nil || !p.analysed { Task { await self.load(p) } }
        kick()
    }

    /// What the look is rendered from: the preview, or with 降噪 on (and for this photo) the preview denoised at full
    /// resolution then reduced (Denoise.preview: denoising a 2400 px copy would differ from the export). Made once and
    /// kept as a bitmap (~30 MB, within the cap of kept previews); nil only before the photo is decoded.
    /// Analysis (tone model, faces, masks, skin plans) stays on the plain preview, so a look's settings do not change.
    nonisolated static func source(_ p: Photo, denoise on: Bool, engine: Engine) -> CIImage? {
        guard let img = p.preview else { return nil }
        guard on, p.denoiseApplies, Denoise.isAvailable else { return img }
        planLock.lock(); let known = p.denoised; planLock.unlock()
        if let known { return known }
        guard let full = try? engine.decode(p.url, maxSide: nil) else { return img }
        let e = img.extent
        let small = Denoise.preview(full, iso: p.iso, isRAW: p.isRAW, maxSide: max(e.width, e.height))
        let fitted = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
            .clampedToExtent().cropped(to: e)       // the same pixels as the plain preview (within a pixel of rounding)
        guard let made = try? engine.strips(fitted) else { return img }
        planLock.lock(); p.denoised = made; planLock.unlock()
        return made
    }

    /// The words under the 降噪 switch: what it does to this batch (RAW and low-ISO photos are left as they are).
    var denoiseNote: String {
        let loaded = photos.filter { $0.preview != nil }
        let raw = loaded.filter(\.isRAW).count, low = loaded.filter { !$0.isRAW && ($0.iso ?? 99999) < 1600 }.count
        let applies = loaded.filter(\.denoiseApplies).count, maxISO = loaded.filter { !$0.isRAW }.compactMap(\.iso).max() ?? 0
        if loaded.isEmpty { return String(localized: "ipad.denoise.note", defaultValue: "夜景、高感光的照片建议打开。只去掉彩色噪点，皮肤和头发的纹理保留。", comment: "Under the denoise switch, no photo loaded yet.") }
        if applies == 0 {
            if low == 0 { return String(localized: "ipad.denoise.allRaw", defaultValue: "RAW 已由系统降噪，这个开关对 RAW 不起作用。", comment: "Under the denoise switch: every photo is RAW.") }
            return String(localized: "ipad.denoise.none", defaultValue: "这批照片都用不上：RAW 已由系统降噪，其余感光度低于 ISO 1600，开着也不会改动。", comment: "Under the denoise switch: no photo would change (RAW or low ISO).")
        }
        var parts: [String] = []
        if maxISO >= 1600 { parts.append(String(localized: "ipad.denoise.noisy", defaultValue: "这批里有高感光的照片（最高 ISO \(maxISO)），建议打开。", comment: "Under the denoise switch. %lld = the highest ISO of the batch.")) }
        if raw + low > 0 {
            parts.append(String(localized: "ipad.denoise.scope", defaultValue: "只对其中 \(applies) 张起作用", comment: "Under the denoise switch. %lld = photos it changes. Followed by the reasons for the others."))
            if raw > 0 { parts.append(String(localized: "ipad.denoise.rawPart", defaultValue: "\(raw) 张 RAW 已由系统降噪", comment: "%lld = RAW photos in the batch, already denoised by the system decoder.")) }
            if low > 0 { parts.append(String(localized: "ipad.denoise.lowPart", defaultValue: "\(low) 张感光度低于 ISO 1600，不用降噪", comment: "%lld = photos below ISO 1600, left unchanged.")) }
        } else if maxISO < 1600 {
            parts.append(String(localized: "ipad.denoise.unknown", defaultValue: "这些照片没有记录感光度，打开时只做轻度降噪。", comment: "Under the denoise switch: no ISO in the files; a mild amount when on."))
        }
        return parts.joined(separator: " ")
    }

    /// 保留本色: this photo's skin plan for a look (SkinKeep), worked out once its faces are known; nil before.
    nonisolated static func skinPlan(_ p: Photo, _ look: Look?, engine: Engine) -> SkinPlan? {
        guard let look, look.style != nil, p.analysed, !p.faces.isEmpty, let img = p.preview else { return nil }
        planLock.lock(); let known = p.skinPlans[look.id]; planLock.unlock()      // the loader and the screen both ask
        if let known { return known }
        let toned = engine.render(img, grade: look.style.flatMap { p.grades[$0] }, tweak: Tweak(extra: look.extra))
        let (n, t) = SkinKeep.samples(neutral: img, toned: toned, faces: p.faces, context: engine.context)
        let plan = SkinKeep.plan(neutral: n, toned: t, s: SkinKeep.depth(p.faces, width: img.extent.width))
        planLock.lock(); p.skinPlans[look.id] = plan; planLock.unlock()
        return plan
    }
    nonisolated static let planLock = NSLock()

    /// The 塑形 plan of a photo for a set of switches (worked out once, on the preview; off the main thread).
    nonisolated static func shapePlan(_ p: Photo, _ set: ShapeSet, men: Bool) -> ShapePlan? {
        let key = set.key + (men ? "m" : "")
        if let ready = p.plans[key] { return ready }
        guard set.slim || set.eyes || set.waist || set.chest || set.legs, let img = p.preview else { p.plans[key] = .some(nil); return nil }
        if (set.waist || set.chest || set.legs) && p.people == nil, let cg = p.original ?? Engine.shared.cgImage(img) { p.people = People.find(cg) }
        let plan = Shaping.plan(size: img.extent.size, faces: p.faces, people: p.people, set: set, men: men)
        p.plans[key] = .some(plan)
        return plan
    }

    // MARK: rendering

    /// Re-renders what is on screen and the look cards. Cheap: the model ran at import.
    func refresh() {
        guard let p = currentPhoto, let img = p.preview else { picture = nil; return }
        let engine = self.engine, look = Look.all.first { $0.id == self.look }
        var tweak = self.tweak; tweak.extra = look?.extra
        let original = showOriginal, level = beauty, amount = Float(beautyAmount), set = shapes, dn = denoise
        let memo = p.memos[self.look] ?? BeautyMemo()
        p.memos[self.look] = memo
        if rendering { again = true; return }
        rendering = true
        let cardMask = p.skinMask
        let needCards = p.cards.isEmpty || p.cardsMask !== cardMask, key = settingsKey
        Task {
            defer { rendering = false; if again { again = false; refresh() } }
            let grade = look?.style.flatMap { p.grades[$0] }
            // the picture first, on its own: the cards come after it
            let main = await Engine.bigStack { () -> CGImage? in
                Engine.lap("refresh start")
                if p.original == nil { p.original = engine.cgImage(img) }      // let go by the cap of kept pictures
                let plan = Studio.shapePlan(p, set, men: level == .men)
                var tweak = tweak; tweak.skin = Studio.skinPlan(p, look, engine: engine); tweak.skinMask = p.skinMask
                let shown = original ? img : engine.render(Studio.source(p, denoise: dn, engine: engine) ?? img, grade: grade, tweak: tweak, beauty: BeautyJob(faces: p.faces, edits: p.edits, level: level, amount: amount, memo: memo, fullWidth: p.fullWidth, shape: plan, evenLight: set.light))
                let main = engine.cgImage(shown)
                Engine.lap("main picture")
                return main
            }
            picture = main; originalPicture = p.original
            if !original { p.shown = main; p.shownKey = key }
            let (cards, faceCards) = await Engine.bigStack { () -> ([String: CGImage], [BeautyLevel: CGImage]) in
                let faceCards: [BeautyLevel: CGImage] = [:]       // (7 levels: one render each was too slow; the slider and the divider show it)
                Engine.lap("face cards")
                // one small picture per look: the same for every tweak, so made once per photo
                var cards: [String: CGImage] = [:]
                if needCards {
                    let s = 360 / max(img.extent.width, img.extent.height)
                    let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                    for l in Look.all {
                        let g = l.style.flatMap { p.grades[$0] }
                        var t = Tweak(extra: l.extra); t.skinMask = cardMask
                        if let c = engine.cgImage(engine.render(small, grade: g, tweak: t)) { cards[l.id] = c }
                    }
                    Engine.lap("look cards")
                }
                return (cards, faceCards)
            }
            if needCards { p.cards = cards; p.cardsMask = cardMask }
            if p.id == current { self.cards = p.cards; self.faceCards = faceCards }
        }
    }

    // MARK: export

    /// Every imported photo, full size, with the chosen look and tweaks, into the photo library.
    func exportAll() {
        let list = photos, engine = self.engine, level = beauty, amount = Float(beautyAmount), set = shapes, dn = denoise
        let chosen = Look.all.first { $0.id == look }, style = chosen?.style, lookID = look
        var tweak = self.tweak; tweak.extra = chosen?.extra
        stage = .exporting(0, list.count)
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                message = "没有存进相册的权限：请在 设置 → 隐私 → 照片 里允许。"; stage = .ready; return
            }
            // the background loading waits during the export (memory: the export alone comes near the iPad's limit);
            // the other photos' kept previews go now and are made again afterwards
            for p in photos where p.id != current { p.shown = nil; p.shownKey = nil }
            engine.context.clearCaches()
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var done = 0
            for (i, p) in list.enumerated() {
                stage = .exporting(i, list.count)
                // retouching needs the faces: a photo the loader has not reached yet is read here
                await load(p)
                guard photos.contains(where: { $0 === p }) else { continue }
                let file: URL? = await Engine.bigStack {
                    var tweak = tweak; tweak.skin = Studio.skinPlan(p, chosen, engine: engine); tweak.skinMask = p.skinMask
                    return try? engine.export(p.url, grade: style.flatMap { p.grades[$0] }, tweak: tweak,
                                      denoise: dn && p.denoiseApplies ? (p.iso, p.isRAW) : nil, faces: p.faces, level: level, amount: amount, memo: p.memos[lookID],
                                      shape: Studio.shapePlan(p, set, men: level == .men), evenLight: set.light, to: out)
                }
                guard let file else { continue }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        let opt = PHAssetResourceCreationOptions(); opt.shouldMoveFile = true
                        req.addResource(with: .photo, fileURL: file, options: opt)
                    }
                    done += 1
                } catch { message = "存进相册失败：\(error.localizedDescription)" }
            }
            stage = .done(done)
            kick()
        }
    }
}
