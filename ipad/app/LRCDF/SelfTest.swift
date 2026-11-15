import CoreImage
import ImageIO
import SwiftUI
import Foundation

/// Runs the app's own engine on one photo without the UI (development check only).
enum SelfTest {
    static var flat = false
    @MainActor static func snapshot(_ files: [URL], _ out: URL) async {
        flat = true
        let studio = Studio()
        studio.add(files)
        for _ in 0..<600 { if studio.stage == .ready && studio.picture != nil && !studio.cards.isEmpty { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
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
        shot("landscape", 1376, 1032)
        shot("portrait", 1032, 1376)
        studio.tweak = Tweak(bright: 1, warm: -1, rich: 2); studio.look = "c"; studio.refresh()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        shot("landscape_c_tweak", 1376, 1032)
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
            let f = try e.export(photo, grade: grades[0], tweak: Tweak(), to: out)
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            print(String(format: "full export %.2fs", Date().timeIntervalSince(t)), f.lastPathComponent, size / 1_000_000, "MB")
        } catch { print("export failed", error) }
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        print("peak footprint MB", info.ledger_phys_footprint_peak / 1_000_000)
    }
}
