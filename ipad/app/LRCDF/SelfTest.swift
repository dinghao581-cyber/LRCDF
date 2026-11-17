import CoreML
import CoreImage
import Vision
import ImageIO
import SwiftUI
import Foundation

#if TESTHOOKS
/// Runs the app's own engine on one photo without the UI (development check only).
enum SelfTest {
    /// --denoise <outdir> <photo>…; see docs/ipad/denoise/REPORT.md for measurement modes.
    static func denoise(_ files: [URL], _ out: URL) -> Bool {
        DenoiseTest.run(files, out)
    }
    static var flat = false
    @MainActor static func snapshot(_ files: [URL], _ out: URL) async {
        flat = true
        let studio = Studio()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let seen = UserDefaults.standard.bool(forKey: "onboarded")
        UserDefaults.standard.set(true, forKey: "onboarded")
        defer { UserDefaults.standard.set(seen, forKey: "onboarded") }      // the user's own first start keeps its tutorial
        for (name, v) in [("welcome", AnyView(RootView().environmentObject(studio))), ("tutorial", AnyView(Onboarding {})), ("rights_prompt", AnyView(ZStack { Room(image: nil); RightsPrompt() })), ("rights_card", AnyView(ZStack { Room(image: nil); RightsCard() }))] {
            let r = ImageRenderer(content: v.environment(\.colorScheme, .dark).frame(width: 1376, height: 1032)); r.scale = 1
            if let cg = r.cgImage, let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d); print("wrote", name)
            }
        }
        #if os(macOS)     // (on the iPad, changing the switch while drawing stops SwiftUI: Mac only)
        // 联机拍摄 page, Wi-Fi then the iPad's hotspot (not receiving: nothing listens)
        let hs = Tether.shared.hotspot
        for (name, h) in [("tether_wifi", false), ("tether_hotspot", true)] {
            Tether.shared.hotspot = h
            let r = ImageRenderer(content: TetherView().environmentObject(studio).environment(\.colorScheme, .dark).frame(width: 700, height: 1100)); r.scale = 1
            if let cg = r.cgImage, let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d); print("wrote", name)
            }
        }
        Tether.shared.hotspot = hs
        #endif
        studio.add(files)
        for _ in 0..<600 { if studio.stage == .ready && studio.picture != nil && !studio.cards.isEmpty && studio.currentPhoto?.analysed == true { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String, _ w: CGFloat, _ h: CGFloat) {
            let v = ZStack { Palette.bg; EditorView(picks: .constant([]), showFiles: .constant(false)) }
                .environmentObject(studio).environment(\.colorScheme, .dark).frame(width: w, height: h)
            let r = ImageRenderer(content: v); r.scale = 1
            if let cg = r.cgImage, let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d); print("wrote", name)
            }
        }
        shot("landscape", 1210, 834)
        shot("portrait", 834, 1210)
        shot("mini_landscape", 1133, 744)      // iPad mini (A17 Pro), points
        shot("mini_portrait", 744, 1133)
        Inspector.startOpen = 0
        studio.tweak = Tweak(bright: 1, warm: 0.6, rich: 0.4, tint: 0.3); studio.look = "c"; studio.refresh()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        shot("landscape_c_tweak", 1210, 834)
    }

    /// Tonewell's save: the photos loaded as the app does, saved into `out` as JPEG, HEIC and TIFF, and JPEG once more
    /// (a second file of the same name must not overwrite the first).
    @MainActor static func studioExport(_ files: [URL], _ out: URL) async {
        let studio = Studio()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for f in files { print("input", f.path, FileManager.default.fileExists(atPath: f.path), (try? Engine.shared.decode(f, maxSide: 2400)) != nil) }
        studio.add(files, sources: files)
        for _ in 0..<1200 { if studio.photos.allSatisfy({ $0.analysed }) { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        for f in [Engine.Format.jpeg, .heic, .tiff, .jpeg] {
            let t = Date()
            studio.exportAll(to: out, format: f)
            for _ in 0..<3000 { if case .done = studio.stage { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            print(f.rawValue, String(format: "%.1fs", -t.timeIntervalSinceNow), studio.stage, studio.message ?? "", "photos", studio.photos.count); studio.message = nil
            studio.stage = .ready
        }
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).sorted() {
            let size = (try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(n).path)[.size] as? Int) ?? 0
            print("  ", n, size / 1000, "kB")
        }
    }

    /// Skin plans from the 512 px render against the preview-size render, every look of every photo: largest differences.
    static func planCheck(_ files: [URL]) {
        let e = Engine.shared, b = Beauty.shared
        var dg: Float = 0, dc: Float = 0, dh: Float = 0, n = 0, tFull = 0.0, tSmall = 0.0
        for url in files {
            guard let img = try? e.decode(url, maxSide: 2400), let g = try? e.grades(for: img) else { continue }
            let p = Photo(url: url); p.preview = img; p.grades = g; p.faces = b.faces(in: img); p.analysed = true
            guard !p.faces.isEmpty else { continue }
            for l in Look.all where l.style != nil {
                var t0 = Date(); let a = Studio.makeSkinPlan(p, l, img, engine: e, side: nil); tFull += -t0.timeIntervalSinceNow
                t0 = Date(); let c = Studio.makeSkinPlan(p, l, img, engine: e, side: 512); tSmall += -t0.timeIntervalSinceNow
                dg = max(dg, abs(a.gain - c.gain)); dc = max(dc, abs(a.chroma - c.chroma))
                if a.chroma > 1.001 || c.chroma > 1.001 { dh = max(dh, abs(a.hue - c.hue)) }
                n += 1
            }
        }
        print(String(format: "plans %d: max |gain| diff %.4f, max |chroma| diff %.4f, max hue diff %.2f deg; time full %.1fs, 512 px %.1fs", n, dg, dc, dh, tFull, tSmall))
    }

    /// Speed profile: each step of loading a photo, one photo at a time, as the app does them: wall time and the process
    /// CPU time over it (CPU/wall near 1 = one core busy; well above 1 = several; near 0 = waiting, e.g. on the GPU).
    /// Totals per step at the end; then one full-size export of the first RAW and the first JPEG (LRCDF_PROFILE_EXPORT=1).
    static func profile(_ files: [URL]) {
        let e = Engine.shared, b = Beauty.shared
        func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
        var tot: [String: (Double, Double)] = [:], order: [String] = []
        func step<T>(_ name: String, _ work: () -> T) -> T {
            let w0 = Date(), c0 = cpu(); let r = work()
            let w = -w0.timeIntervalSinceNow, c = cpu() - c0
            if tot[name] == nil { order.append(name) }
            tot[name, default: (0, 0)].0 += w; tot[name, default: (0, 0)].1 += c
            return r
        }
        for url in files {
            guard let img = step("decode preview", { try? e.decode(url, maxSide: 2400) }) else { continue }
            let g = step("tone model (LUTNet2 x3)", { (try? e.grades(for: img)) ?? [:] })
            _ = step("thumb + original", { (e.cgImage(img.transformed(by: CGAffineTransform(scaleX: 220 / max(img.extent.width, img.extent.height), y: 220 / max(img.extent.width, img.extent.height)))), e.cgImage(img)) })
            let faces = step("faces (Vision, RetinaFace, segmenter, make-up)", { b.faces(in: img) })
            let edits = step("blemish model (RetouchNet)", { b.edits(img, faces: faces, fullWidth: img.extent.width) })
            let mask = step("skin mask", { SkinOnly.mask(img, context: e.context) })
            let p = Photo(url: url); p.preview = img; p.grades = g; p.faces = faces; p.edits = edits; p.analysed = true; p.skinMask = mask
            let look = Look.all.first { $0.id == "a" }
            _ = step("finished preview (look a + retouching)", { () -> CGImage? in
                var t = Tweak(); t.skin = Studio.skinPlan(p, look, engine: e); t.skinMask = mask
                return e.cgImage(e.render(img, grade: g[0], tweak: t, beauty: BeautyJob(faces: faces, edits: edits, level: .auto, memo: BeautyMemo(), fullWidth: img.extent.width)))
            })
            _ = step("round 2: skin plans of all looks", { let looks = Look.all.filter { $0.style != nil }; DispatchQueue.concurrentPerform(iterations: looks.count) { _ = Studio.skinPlan(p, looks[$0], engine: e) } })
            _ = step("round 2: look cards", { Studio.lookCards(img, p, mask: mask, engine: e) })
            e.context.clearCaches(); b.context.clearCaches()
        }
        let allW = tot.values.map(\.0).reduce(0, +)
        print(String(format: "TOTAL %.1fs for %d photos", allW, files.count))
        for k in order { let (w, c) = tot[k]!; print(String(format: "  %-48@ %6.1fs %4.0f%%  cpu/wall %.2f", k as NSString, w, w / allW * 100, c / max(w, 1e-6))) }
        guard Beauty.testEnv["LRCDF_PROFILE_EXPORT"] == "1" else { return }
        for url in [files.first { Denoise.isRAW($0) }, files.first { !Denoise.isRAW($0) }].compactMap({ $0 }) {
            guard let img = try? e.decode(url, maxSide: 2400), let g = try? e.grades(for: img) else { continue }
            let faces = b.faces(in: img)
            var t = Tweak(); t.skinMask = SkinOnly.mask(img, context: e.context)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("profile_export")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let w0 = Date(), c0 = cpu()
            _ = try? e.export(url, grade: g[0], tweak: t, faces: faces, level: .auto, to: out)
            let w = -w0.timeIntervalSinceNow
            print(String(format: "export %@: %.2fs cpu/wall %.2f", url.lastPathComponent, w, (cpu() - c0) / w))
        }
    }

    /// Where each Core ML model runs (MLComputePlan): operations per preferred device, and the share of the
    /// estimated cost on each; then the time of one prediction-sized warm run is left to --loadall's laps.
    @available(macOS 14.4, iOS 17.4, *)
    static func computePlan() async {
        let config = MLModelConfiguration(); config.computeUnits = .all
        for name in ["LUTNet2", "SelfieSeg", "RetouchNet", "RetinaFace", "Critic", "Makeup"] {
            guard let url = ModelStore.url(name), let plan = try? await MLComputePlan.load(contentsOf: url, configuration: config) else { print(name, "no plan"); continue }
            var ops: [String: Int] = [:], cost: [String: Double] = [:]
            func walk(_ block: MLModelStructure.Program.Block) {
                for op in block.operations {
                    let dev: String
                    switch plan.deviceUsage(for: op)?.preferred {
                    case .cpu: dev = "CPU"; case .gpu: dev = "GPU"; case .neuralEngine: dev = "ANE"; default: dev = "-"
                    }
                    ops[dev, default: 0] += 1
                    cost[dev, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
                    for b in op.blocks { walk(b) }
                }
            }
            if case .program(let prog) = plan.modelStructure, let main = prog.functions["main"] { walk(main.block) }
            else if case .program(let prog) = plan.modelStructure { for f in prog.functions.values { walk(f.block) } }
            let total = max(cost.values.reduce(0, +), 1e-9)
            print(name, ops.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) ops \(Int((cost[$0.key] ?? 0) / total * 100))%" }.joined(separator: ", "))
        }
    }

    /// 降噪 in the app's own export (look d, as the app exports it): each photo with the switch off and on
    /// (LRCDF_DN=off|on|both, default both), into <out>/off and <out>/on; the on-export always passes the file's ISO and
    /// type, so RAW and low ISO show the engine's own bypass. Times and the process peak on stdout.
    static func denoiseExport(_ files: [URL], _ out: URL) {
        let e = Engine.shared, mode = ProcessInfo.processInfo.environment["LRCDF_DN"] ?? "both"
        for url in files {
            guard let prev = try? e.decode(url, maxSide: 2400) else { print(url.lastPathComponent, "decode failed"); continue }
            let g = (try? e.grades(for: prev))?[0]
            var tk = Tweak(extra: "d"); tk.skinMask = SkinOnly.mask(prev, context: e.context)
            for on in [false, true] where mode == "both" || (mode == "on") == on {
                let dir = out.appendingPathComponent(on ? "on" : "off")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let t = Date()
                let dn: (iso: Int?, isRAW: Bool)? = on ? (Denoise.iso(url), Denoise.isRAW(url)) : nil
                _ = try? e.export(url, grade: g, tweak: tk, denoise: dn, to: dir)
                var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
                print(url.lastPathComponent, on ? "on " : "off", "iso", Denoise.iso(url) ?? -1, "raw", Denoise.isRAW(url),
                      String(format: "%.2fs", -t.timeIntervalSinceNow), "peak MB", info.ledger_phys_footprint_peak / 1_000_000)
            }
        }
    }

    /// 导入即加载: a batch imported at once. Prints when the first picture shows, how long a switch to a photo far down
    /// the list and a look change take while the loader works, when rounds 1 and 2 end, and the peak memory.
    @MainActor static func loadall(_ files: [URL]) async {
        let studio = Studio(), t0 = Date()
        func at() -> String { String(format: "%6.1fs", -t0.timeIntervalSinceNow) }
        func peak() -> Int {
            var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
            return Int(info.ledger_phys_footprint_peak / 1_000_000)
        }
        func shown() -> Bool { if let p = studio.currentPhoto, let s = p.shown { return studio.picture === s } ; return false }
        func wait(_ what: String, _ ok: () -> Bool) async -> Double {
            let t = Date()
            for _ in 0..<1200 { if ok() { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
            let d = -t.timeIntervalSinceNow; print(at(), what, String(format: "%.2fs", d), studio.progress?.what ?? "-"); return d
        }
        let keepDN = studio.denoise
        studio.denoise = ProcessInfo.processInfo.environment["LRCDF_DENOISE"] == "1"     // 降噪 on for the batch (test)
        defer { studio.denoise = keepDN }
        print("photos", files.count, "roomy", Studio.roomy, "denoise", studio.denoise)
        studio.add(files)
        _ = await wait("first picture", { studio.picture != nil })
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for k in [files.count - 3, files.count / 2] where k > 0 {           // far down the list, probably not loaded yet
            let id = studio.photos[k].id
            studio.select(id)
            _ = await wait("switch to photo \(k + 1)", { studio.current == id && shown() })
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        studio.look = "c"; studio.settingsChanged()
        _ = await wait("look change to c", { studio.currentPhoto?.shownKey?.hasPrefix("c|") == true && shown() })
        _ = await wait("round 1 done", { !(studio.progress?.what.hasPrefix("正在加载") ?? false) })
        _ = await wait("round 2 done", { studio.progress == nil })
        print(at(), "peak footprint MB", peak())
    }

    /// Retouching only: each photo at preview size with the neutral render, at every level, plus timings.
    static func beauty(_ files: [URL], _ out: URL, full: Bool) {
        let e = Engine.shared, b = Beauty.shared
        print("beauty models loaded:", b.ready); Engine.mem("models")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard let img = try? e.decode(url, maxSide: 2400) else { print(name, "decode failed"); continue }
            var t = Date()
            Engine.mem("preview decode")
            let faces = b.faces(in: img)
            Engine.mem("faces")
            let tf = Date().timeIntervalSince(t); t = Date()
            let edits = b.edits(img, faces: faces, fullWidth: e.fullWidth(url) ?? img.extent.width)
            print(name, String(format: "faces %d (%.2fs), blemish model %d (%.2fs)", faces.count, tf, edits.compactMap { $0 }.count, Date().timeIntervalSince(t)),
                  faces.map { Int($0.width * img.extent.width) })
            Engine.mem("blemish model")
            let memo = BeautyMemo()
            for l in (ProcessInfo.processInfo.environment["LRCDF_EXPORT_ONLY"] != nil ? [.natural] : BeautyLevel.allCases + [.natural]) {
                if l == .natural, ProcessInfo.processInfo.environment["LRCDF_DEBUG"] != nil {
                    Beauty.debugDir = out; Beauty.debugName = name
                } else { Beauty.debugDir = nil }
                t = Date()
                let r = e.render(img, grade: nil, tweak: Tweak(), beauty: BeautyJob(faces: faces, edits: edits, level: l, memo: memo))
                try? e.context.writeJPEGRepresentation(of: r, to: out.appendingPathComponent("\(name)_\(l.rawValue).jpg"), colorSpace: e.srgb,
                                                       options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
                print("  ", l.rawValue, String(format: "render %.2fs", Date().timeIntervalSince(t)))
                Engine.mem(l.rawValue)
            }
            if full {
                t = Date()
                if let f = try? e.export(url, grade: nil, tweak: Tweak(), faces: faces, level: .natural, memo: memo, to: out) {
                    print("   full export with beauty", String(format: "%.2fs", Date().timeIntervalSince(t)), f.lastPathComponent)
                }
            }
        }
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        print("peak footprint MB", info.ledger_phys_footprint_peak / 1_000_000)
    }

    static func run(_ photo: URL, _ out: URL) {
        let e = Engine.shared
        print("model loaded:", e.modelReady)
        var t = Date()
        guard let prev = try? e.decode(photo, maxSide: 2400) else { print("decode failed"); return }
        print(String(format: "preview decode %.2fs %dx%d", Date().timeIntervalSince(t), Int(prev.extent.width), Int(prev.extent.height)))
        t = Date()
        let grades = (try? e.grades(for: prev)) ?? [:]
        print(String(format: "model %.3fs", Date().timeIntervalSince(t)), grades.mapValues { ($0.shadows, $0.highlights) })
        // 橙黄只落皮肤 (SkinOnly): its own costs (grades() above already includes the three second tables when it is on)
        if let g0 = grades[0] {
            t = Date(); let cube = g0.cube.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            _ = SkinOnly.flatten(cube, Engine.D)
            print(String(format: "skinonly: second table %.3fs (x3 styles in model time), on=%d", Date().timeIntervalSince(t), SkinOnly.on ? 1 : 0))
        }
        t = Date()
        let mask = SkinOnly.on ? SkinOnly.mask(prev, context: e.context) : nil
        print(String(format: "skinonly: mask %.3fs, skin %.1f%%", Date().timeIntervalSince(t), 100 * (mask?.share ?? 0)))
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in Look.all {
            t = Date()
            let g = look.style.flatMap { grades[$0] }
            let img = e.render(prev, grade: g, tweak: Tweak())
            try? e.context.writeJPEGRepresentation(of: img, to: out.appendingPathComponent("prev_\(look.id).jpg"), colorSpace: e.srgb)
            print(look.id, String(format: "preview render %.2fs", Date().timeIntervalSince(t)))
        }
        let tw = e.render(prev, grade: grades[0], tweak: Tweak(bright: 2, warm: 2, rich: 2))
        try? e.context.writeJPEGRepresentation(of: tw, to: out.appendingPathComponent("prev_a_tweak222.jpg"), colorSpace: e.srgb)
        t = Date()
        do {
            var tk = Tweak(extra: "d"); tk.skinMask = mask      // the default look, as the app exports it
            let f = try e.export(photo, grade: grades[0], tweak: tk, to: out)
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            print(String(format: "full export %.2fs", Date().timeIntervalSince(t)), f.lastPathComponent, size / 1_000_000, "MB")
        } catch { print("export failed", error) }
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        print("peak footprint MB", info.ledger_phys_footprint_peak / 1_000_000)
    }

    static func tweaks(_ photo: URL, _ out: URL) {
        let e = Engine.shared
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let img = try? e.decode(photo, maxSide: 900) else { return }
        let g = try? e.grades(for: img)
        var list: [(String, Tweak)] = [("base", Tweak())]
        for (n, k) in [("tint", \Tweak.tint), ("contrast", \Tweak.contrast), ("highlights", \Tweak.highlights), ("shadows", \Tweak.shadows)] as [(String, WritableKeyPath<Tweak, Double>)] {
            for v in [-2.0, 2.0] { var t = Tweak(); t[keyPath: k] = v; list.append(("\(n)\(v > 0 ? "+" : "-")", t)) }
        }
        var sh = Tweak(); sh.shadowHue = 200; sh.shadowSat = 0.6; list.append(("shadow200", sh))
        var hi = Tweak(); hi.highlightHue = 40; hi.highlightSat = 0.6; list.append(("highlight40", hi))
        for (name, t) in list {
            let r = e.render(img, grade: g?[0], tweak: t)
            try? e.context.writeJPEGRepresentation(of: r, to: out.appendingPathComponent(name + ".jpg"), colorSpace: e.srgb, options: [:])
            print("wrote", name)
        }
    }

    static func shape(_ files: [URL], _ out: URL) {
        let e = Engine.shared, b = Beauty.shared
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard let img = try? e.decode(url, maxSide: 1600), let cg = e.cgImage(img) else { continue }
            let faces = b.faces(in: img)
            let t0 = Date(); let people = People.find(cg)
            print(name, "faces", faces.count, "bodies", people.bodies.count, String(format: "people %.2fs", Date().timeIntervalSince(t0)))
            for bd in people.bodies.prefix(2) {
                for j in [VNHumanBodyPoseObservation.JointName.nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle] {
                    if let (pt, c) = bd.joints[j] { print(String(format: "     %@ x %.0f y %.0f c %.2f", j.rawValue.rawValue, pt.x, pt.y, c)) } else { print("     \(j.rawValue.rawValue) missing") }
                }
                print("     torso:", Shaping.torso(bd) != nil, "image", Int(img.extent.width), Int(img.extent.height))
            }
            var sets: [(String, ShapeSet)] = [("none", ShapeSet())]
            for k in ["slim", "eyes", "waist", "chest", "legs", "light"] {
                var st = ShapeSet()
                switch k { case "slim": st.slim = true; case "eyes": st.eyes = true; case "waist": st.waist = true
                case "chest": st.chest = true; case "legs": st.legs = true; default: st.light = true }
                sets.append((k, st))
            }
            sets.append(("all", ShapeSet(slim: true, eyes: true, waist: true, chest: true, legs: true, light: true)))
            for (k, st) in sets {
                let plan = Shaping.plan(size: img.extent.size, faces: faces, people: people, set: st, men: false)
                let r = e.render(img, grade: nil, tweak: Tweak(), beauty: BeautyJob(faces: faces, edits: [], level: .off, shape: plan, evenLight: st.light))
                try? e.context.writeJPEGRepresentation(of: r, to: out.appendingPathComponent("\(name)_\(k).jpg"), colorSpace: e.srgb, options: [:])
                print("  ", k, plan?.notes ?? [])
            }
        }
    }

    /// 橙黄只落皮肤 (SkinOnly): per photo the looks as the app makes them now and with the switch on, the mask, the faces'
    /// skin maps (for measuring), and with LRCDF_CHART=<picture> that picture through each photo's looks, table as made
    /// vs flattened (no skin in a colour chart: the flattened table everywhere).
    static func skinonly(_ files: [URL], _ out: URL) {
        SkinOnly.on = true
        let e = Engine.shared, b = Beauty.shared
        try? FileManager.default.createDirectory(at: out.appendingPathComponent("chart"), withIntermediateDirectories: true)
        func save(_ img: CIImage, _ name: String) {
            try? e.context.writePNGRepresentation(of: img, to: out.appendingPathComponent(name + ".png"), format: .RGBA8, colorSpace: e.srgb)
        }
        let chart = ProcessInfo.processInfo.environment["LRCDF_CHART"].flatMap { try? e.decode(URL(fileURLWithPath: $0), maxSide: 720) }
        let looks = Look.all.filter { $0.style != nil }
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard let img = try? e.decode(url, maxSide: 1200) else { print(name, "decode failed"); continue }
            let faces = b.faces(in: img)
            guard let g = try? e.grades(for: img) else { continue }
            let t0 = Date()
            let mask = SkinOnly.mask(img, context: e.context)
            let ms = -t0.timeIntervalSinceNow * 1000
            save(e.render(img, grade: nil, tweak: Tweak()), name + "_neutral")
            if let m = mask { save(m.over(img.extent), name + "_mask") }
            for l in looks where ["a", "d", "e", "f", "b"].contains(l.id) {
                let grade = g[l.style!]
                var tk = Tweak(extra: l.extra)
                if !faces.isEmpty {
                    let toned = e.render(img, grade: grade, tweak: tk)
                    let (sn, st) = SkinKeep.samples(neutral: img, toned: toned, faces: faces, context: e.context)
                    tk.skin = SkinKeep.plan(neutral: sn, toned: st, s: SkinKeep.depth(faces, width: img.extent.width))
                }
                save(e.render(img, grade: grade, tweak: tk), "\(name)_\(l.id)_now")
                tk.skinMask = mask
                save(e.render(img, grade: grade, tweak: tk), "\(name)_\(l.id)_so")
                if let c = chart {
                    save(e.render(c, grade: grade, tweak: Tweak(extra: l.extra)), "chart/\(name)_\(l.id)_now")
                    var t = Tweak(extra: l.extra); t.skinMask = SkinOnly.Mask.none
                    save(e.render(c, grade: grade, tweak: t), "chart/\(name)_\(l.id)_so")
                }
            }
            var fm = CIImage(color: .black).cropped(to: img.extent)
            for f in faces {
                guard let s = f.skin else { continue }
                let a = CGRect(x: f.area.minX * img.extent.width, y: f.area.minY * img.extent.height, width: f.area.width * img.extent.width, height: f.area.height * img.extent.height)
                let m = s.transformed(by: CGAffineTransform(scaleX: a.width / 256, y: a.height / 256).concatenating(CGAffineTransform(translationX: a.minX, y: a.minY)))
                fm = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: fm]).cropped(to: img.extent)
            }
            save(fm, name + "_skin")
            print(name, "faces", faces.count, String(format: "mask %.1f%% %.0f ms", 100 * (mask?.share ?? 0), ms))
        }
        if let c = chart { save(c, "chart/neutral") }
    }

    static func skinlab(_ files: [URL], _ out: URL, beautyOnly: Bool) {
        let e = Engine.shared, b = Beauty.shared
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func save(_ img: CIImage, _ name: String) {
            try? e.context.writePNGRepresentation(of: img, to: out.appendingPathComponent(name + ".png"), format: .RGBA8, colorSpace: e.srgb)
        }
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard let img = try? e.decode(url, maxSide: 1200) else { print(name, "decode failed"); continue }
            let faces = b.faces(in: img)
            guard !faces.isEmpty else { print(name, "no face"); continue }
            let edits = b.edits(img, faces: faces, fullWidth: img.extent.width)
            let job = { (l: BeautyLevel) in BeautyJob(faces: faces, edits: edits, level: l, memo: BeautyMemo()) }
            save(e.render(img, grade: nil, tweak: Tweak(), beauty: job(.auto)), name + "_beauty")
            if beautyOnly { print(name, "faces", faces.count); continue }
            let g = try? e.grades(for: img)
            save(e.render(img, grade: nil, tweak: Tweak()), name + "_neutral")
            save(e.render(img, grade: g?[0], tweak: Tweak()), name + "_tone")
            save(e.render(img, grade: g?[0], tweak: Tweak(extra: "d")), name + "_lutd")
            var light = job(.off); light.evenLight = true
            save(e.render(img, grade: nil, tweak: Tweak(), beauty: light), name + "_light")
            save(e.render(img, grade: g?[0], tweak: Tweak(), beauty: job(.auto)), name + "_default")
            // 保留本色 (SkinKeep): the plan as the app makes it, and the look with it
            let toned = e.render(img, grade: g?[0], tweak: Tweak())
            let (sn, st) = SkinKeep.samples(neutral: img, toned: toned, faces: faces, context: e.context)
            let sd = SkinKeep.depth(faces, width: img.extent.width)
            let sp = SkinKeep.plan(neutral: sn, toned: st, s: sd)
            var tk = Tweak(); tk.skin = sp
            save(e.render(img, grade: g?[0], tweak: tk), name + "_keep")
            save(e.render(img, grade: g?[0], tweak: tk, beauty: job(.auto)), name + "_keepdefault")
            print(name, String(format: "skin depth score %.2f s %.2f gain %.3f chroma %.3f hue %.0f px %d", faces.map(\.depth).max() ?? -10, sd, sp.gain, sp.chroma, sp.hue, sn.count))
            // skin: the faces' skin maps (MediaPipe selfie multiclass face-skin + body-skin) over their areas
            var mask = CIImage(color: .black).cropped(to: img.extent)
            for f in faces {
                guard let s = f.skin else { continue }
                let a = CGRect(x: f.area.minX * img.extent.width, y: f.area.minY * img.extent.height, width: f.area.width * img.extent.width, height: f.area.height * img.extent.height)
                let m = s.transformed(by: CGAffineTransform(scaleX: a.width / 256, y: a.height / 256).concatenating(CGAffineTransform(translationX: a.minX, y: a.minY)))
                mask = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: img.extent)
            }
            try? e.context.writePNGRepresentation(of: mask, to: out.appendingPathComponent(name + "_skin.png"), format: .RGBA8, colorSpace: e.srgb)
            print(name, "faces", faces.count)
        }
    }
}
#else
/// Release builds: no self-test code at all (only the switch the views ask about).
enum SelfTest { static let flat = false }
#endif
