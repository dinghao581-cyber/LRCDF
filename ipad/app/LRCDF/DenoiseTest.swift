#if TESTHOOKS
import CoreImage
import Foundation
import ImageIO

/// Measurements use the same decoder, working space, strip renderer and HEIC writer as Engine.
/// Outputs are deliberately outside the application UI and require a TESTHOOKS build.
enum DenoiseTest {
    struct Patch: Codable {
        let name: String
        let kind: String
        let x: Int
        let y: Int
        let size: Int
    }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let env = ProcessInfo.processInfo.environment

    static func run(_ files: [URL], _ out: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let manifestURL = out.appendingPathComponent("patches.json")
            let patches = (try? JSONDecoder().decode([String: [Patch]].self, from: Data(contentsOf: manifestURL))) ?? [:]
            try autoreleasepool {
                let ctx = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
                try invariants(ctx, out)
            }
            var succeeded = true
            for url in files {
                do { try autoreleasepool {
                    // A context belongs to one photo, as in Engine.export.
                    // clearCaches alone does not release every RAW/GPU resource
                    // retained by a long-lived context across a large batch.
                    let ctx = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
                    defer { ctx.clearCaches(); Engine.shared.context.clearCaches() }
                    try measure(url, out, patches[url.lastPathComponent], ctx)
                } }
                catch { succeeded = false; print("DENOISE ERROR", url.lastPathComponent, error) }
            }
            return succeeded
        } catch { print("DENOISE ERROR", error); return false }
    }

    private static func writeJSON(_ value: Any, _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    private static func png(_ image: CIImage, _ url: URL, _ ctx: CIContext) throws {
        // Lossless 16-bit sRGB numbers; no JPEG noise is added to the measurements.
        try ctx.writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: srgb)
    }
    private static func small(_ image: CIImage) -> CIImage {
        Denoise.preview(image, iso: nil, strength: 0)
    }
    private static func footprint() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return result == KERN_SUCCESS ? ["phys_footprint": info.phys_footprint,
                                         "ledger_phys_footprint_peak": UInt64(max(0, info.ledger_phys_footprint_peak))] : [:]
    }
    private static func raw(_ url: URL, mode: String) -> CIRAWFilter? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let versions = f.supportedDecoderVersions.filter { !$0.rawValue.isEmpty && $0.rawValue != "None" }
        guard let v = versions.last else { return nil }
        f.decoderVersion = v
        if mode == "unedited" {
            // RAW 9's learned demosaic / chroma cleanup cannot be disabled with these knobs.
            if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
            if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
        } else if mode == "raw_strong" {
            if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0.8 }
            if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 1 }
            if f.isDetailSupported { f.detailAmount = 1 }
        } else if mode == "raw_gentle" {
            if f.isLuminanceNoiseReductionSupported {
                f.luminanceNoiseReductionAmount = min(1, f.luminanceNoiseReductionAmount + 0.05)
            }
        }
        return f
    }

    private static func measure(_ url: URL, _ out: URL, _ selected: [Patch]?, _ ctx: CIContext) throws {
        let e = Engine.shared, name = url.lastPathComponent
        let folder = out.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadataISO = Denoise.iso(url)
        let isRAW = Denoise.isRAW(url)
        let iso = env["LRCDF_DENOISE_ISO"].flatMap(Int.init) ?? metadataISO
        let strength = env["LRCDF_DENOISE_STRENGTH"].flatMap(Float.init) ?? 1
        let mode = env["LRCDF_DENOISE_MODE"] ?? "compare"
        var result: [String: Any] = ["file": name, "metadata_iso": metadataISO as Any? ?? NSNull(),
            "effective_iso": iso as Any? ?? NSNull(), "strength": strength, "mode": mode, "is_raw": isRAW,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString]
        if let r = raw(url, mode: "current") {
            result["raw"] = ["decoder": r.decoderVersion.rawValue, "supported": r.supportedDecoderVersions.map(\.rawValue),
                "luminance": r.luminanceNoiseReductionAmount, "color": r.colorNoiseReductionAmount,
                "detail": r.detailAmount, "sharpness": r.sharpnessAmount, "contrast": r.contrastAmount,
                "luminance_supported": r.isLuminanceNoiseReductionSupported, "color_supported": r.isColorNoiseReductionSupported,
                "detail_supported": r.isDetailSupported]
        }
        Engine.mem("denoise start \(name)")
        let start = Date()
        if mode == "export" {
            let direct = env["LRCDF_DENOISE_DIRECT"] == "1"
            var decodeSeconds = 0.0, filterSeconds = 0.0
            // Release the full decoded input before HEIC encoding, as Engine.export does.
            let finished = try autoreleasepool { () throws -> CIImage in
                // Only the CPU-backed half-float result crosses this scope.
                // Releasing the render context before HEIC encoding also lets
                // go of decoder/GPU pools that clearCaches may keep allocated.
                let renderContext = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
                defer { renderContext.clearCaches() }
                let t = Date()
                let native = try e.decode(url, maxSide: nil)
                result["width"] = native.extent.width; result["height"] = native.extent.height
                if direct {
                    // Decode and filter lazily in one strip pass: no retained
                    // half-float copy of the unfiltered 60 MP input.
                    let rendered = try e.strips(Denoise.apply(native, iso: iso, strength: strength, isRAW: isRAW), context: renderContext)
                    filterSeconds = -t.timeIntervalSinceNow
                    Engine.mem("denoise decoded + filtered direct")
                    return rendered
                }
                let decoded = try e.strips(native, context: renderContext)
                decodeSeconds = -t.timeIntervalSinceNow
                renderContext.clearCaches(); Engine.mem("denoise decoded")
                let f = Date()
                let rendered = try e.strips(Denoise.apply(decoded, iso: iso, strength: strength, isRAW: isRAW), context: renderContext)
                filterSeconds = -f.timeIntervalSinceNow
                Engine.mem("denoise filtered")
                return rendered
            }
            ctx.clearCaches()
            Engine.mem("denoise render context released")
            let encodeStart = Date()
            try ctx.writeHEIF10Representation(of: finished, to: folder.appendingPathComponent("denoised_full.heic"),
                colorSpace: e.displayP3, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
            result["input_materialized"] = !direct
            result["scoped_render_context"] = true
            if direct { result["decode_filter_seconds"] = filterSeconds }
            else { result["decode_seconds"] = decodeSeconds; result["filter_seconds"] = filterSeconds }
            result["encode_seconds"] = -encodeStart.timeIntervalSinceNow
            result["export_seconds"] = -start.timeIntervalSinceNow
            Engine.mem("denoise written")
        } else if mode == "preview" {
            // First native decode + selected filter + 2400 px render in a fresh
            // process. PNG encoding is intentionally outside the timed stage.
            let t = Date()
            let source = try e.decode(url, maxSide: nil)
            let image = Denoise.preview(source, iso: iso, strength: strength, isRAW: isRAW)
            let preview = try e.strips(image, context: ctx)
            result["native_width"] = source.extent.width; result["native_height"] = source.extent.height
            result["width"] = preview.extent.width; result["height"] = preview.extent.height
            result["preview_seconds"] = -t.timeIntervalSinceNow
            try png(preview, folder.appendingPathComponent("denoised.png"), ctx)
        } else {
            let full = try e.decode(url, maxSide: nil)
            result["width"] = full.extent.width; result["height"] = full.extent.height
            let denoised = Denoise.apply(full, iso: iso, strength: strength, isRAW: isRAW)
            if mode == "regression" {
                let sameImage = denoised === full
                result["same_image_instance"] = sameImage
                if let iso, iso < 1600, !sameImage {
                    throw EngineError.unreadable("known low-ISO filter must return the original graph")
                }
                let before = pixels(small(full), ctx)
                let after = pixels(small(denoised), ctx)
                result["linear_difference"] = difference(before, after)
                result["seconds"] = -start.timeIntervalSinceNow
            } else {
                let base = raw(url, mode: "unedited")?.outputImage ?? full
                let ci = full.applyingFilter("CILinearToSRGBToneCurve")
                    .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0])
                    .applyingFilter("CISRGBToneCurveToLinear").cropped(to: full.extent)
                var variants: [(String, CIImage)] = [("unedited", base), ("current", full), ("denoised", denoised), ("ci_noise", ci)]
                if let strong = raw(url, mode: "raw_strong")?.outputImage { variants.append(("raw_strong", strong)) }
                if let gentle = raw(url, mode: "raw_gentle")?.outputImage { variants.append(("raw_gentle", gentle)) }
                if isRAW { variants.append(("raw_chroma", Denoise.apply(full, iso: iso, strength: strength))) }
                let n = min(256, Int(min(full.extent.width, full.extent.height)))
                let patches = selected ?? [Patch(name: "centre_unreviewed", kind: "diagnostic", x: (Int(full.extent.width) - n) / 2,
                                                  y: (Int(full.extent.height) - n) / 2, size: n)]
                result["patches_reviewed"] = selected != nil
                result["patches"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patches))
                var timings: [String: Double] = [:]
                for (variant, image) in variants {
                    ctx.clearCaches()
                    let t = Date()
                    // Force completion into a small half-float buffer; timing includes full native decode.
                    let preview = try e.strips(small(image), context: ctx)
                    timings[variant + "_preview_render_seconds"] = -t.timeIntervalSinceNow
                    try png(preview, folder.appendingPathComponent(variant + ".png"), ctx)
                    for p in patches {
                        let bounds = CGRect(x: full.extent.minX + CGFloat(p.x),
                            y: full.extent.maxY - CGFloat(p.y + p.size), width: CGFloat(p.size), height: CGFloat(p.size))
                        guard full.extent.contains(bounds) else { throw EngineError.unreadable("patch outside image: \(p.name)") }
                        try png(image.cropped(to: bounds), folder.appendingPathComponent("\(p.name)_\(variant).png"), ctx)
                    }
                }
                // A materialized native export downscaled must agree with the preview graph.
                if env["LRCDF_DENOISE_PARITY"] == "1" {
                    let native = try e.strips(denoised, context: ctx)
                    result["preview_export_linear_difference"] = difference(pixels(small(denoised), ctx), pixels(small(native), ctx))
                }
                result["timings"] = timings
            }
        }
        result["memory_bytes"] = footprint()
        try writeJSON(result, folder.appendingPathComponent("run.json"))
        print("DENOISE", name, "ISO", iso ?? -1, "mode", mode, "seconds", -start.timeIntervalSinceNow)
        Engine.mem("denoise end \(name)")
    }

    private static func pixels(_ image: CIImage, _ ctx: CIContext) -> [Float] {
        let b = image.extent.integral, w = Int(b.width), h = Int(b.height)
        var p = [Float](repeating: 0, count: w * h * 4)
        p.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: b, format: .RGBAf, colorSpace: linear) }
        return p
    }
    private static func difference(_ a: [Float], _ b: [Float]) -> [String: Double] {
        guard a.count == b.count, !a.isEmpty else { return ["count_mismatch": 1] }
        var maxDiff: Float = 0, sum = 0.0
        for i in a.indices { let d = abs(a[i] - b[i]); maxDiff = max(maxDiff, d); sum += Double(d) }
        return ["max": Double(maxDiff), "mean": sum / Double(a.count)]
    }
    private static func invariants(_ ctx: CIContext, _ out: URL) throws {
        guard Denoise.isAvailable else { throw EngineError.unreadable("denoise kernel compilation failed") }
        let w = 96, h = 80
        var p = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let k = 4 * (y * w + x), v = Float((x * 17 + y * 29) % 101) / 100
            p[k] = v * 1.8 - 0.1; p[k + 1] = 0.1 + v * 0.4; p[k + 2] = 1.2 - v
            p[k + 3] = 1
        } }
        let data = p.withUnsafeBytes { Data($0) }
        let img = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
            .transformed(by: CGAffineTransform(translationX: 17, y: -9))
        let processed = Denoise.apply(img, iso: 6400, strength: 1)
        let before = pixels(img, ctx), after = pixels(processed, ctx)
        guard processed.extent == img.extent, after.allSatisfy(\.isFinite) else { throw EngineError.unreadable("denoise extent / finite invariant") }
        let off = difference(before, pixels(Denoise.apply(img, iso: 6400, strength: 0), ctx))
        let low = difference(before, pixels(Denoise.apply(img, iso: 100, strength: 1), ctx))
        let oldRows = Engine.stripRows; Engine.stripRows = 17
        defer { Engine.stripRows = oldRows }
        let tiled = difference(after, pixels(try Engine.shared.strips(processed, context: ctx), ctx))
        var maxLuma = 0.0
        for k in stride(from: 0, to: before.count, by: 4) {
            let delta = abs(0.2126 * Double(after[k] - before[k]) + 0.7152 * Double(after[k+1] - before[k+1]) + 0.0722 * Double(after[k+2] - before[k+2]))
            maxLuma = max(maxLuma, delta)
        }
        guard off["max"] == 0, low["max"] == 0, (tiled["max"] ?? 1) < 0.003, maxLuma < 0.003 else {
            throw EngineError.unreadable("denoise pixel invariant: \(off) \(low) \(tiled) luma \(maxLuma)")
        }
        let fixtures = try fixtureChecks(out)
        try writeJSON(["off": off, "low_iso": low, "strips_vs_direct": tiled, "fixtures": fixtures,
            "max_linear_luminance_error": maxLuma, "extent_preserved": true, "finite": true,
            "note": "Strip result is half-float, direct result float32. Synthetic extended-range RGB, translated extent."], out.appendingPathComponent("invariants.json"))
    }

    /// A no-op filter must fail this test even if it preserves every other
    /// invariant. Small deterministic fixtures also exercise colour boundaries,
    /// alpha, luminance texture and ImageIO's legacy / extended ISO fields.
    private static func fixtureChecks(_ out: URL) throws -> [String: Any] {
        let ctx = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
                                      .cacheIntermediates: false])
        let w = 96, h = 64
        func image(_ p: [Float]) -> CIImage {
            CIImage(bitmapData: p.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16,
                    size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        }
        func chromaSD(_ p: [Float]) -> Double {
            var values: [Double] = []
            for y in 8..<(h - 8) { for x in 8..<(w - 8) {
                let i = 4 * (y * w + x); values.append(Double(p[i] - p[i + 1]))
            } }
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
        }
        var state: UInt32 = 101
        func random() -> Float {
            state = 1664525 &* state &+ 1013904223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
        var noisy = [Float](repeating: 1, count: w * h * 4)
        var edge = noisy, texture = noisy, translucent = noisy, warm = noisy
        for y in 0..<h { for x in 0..<w {
            let i = 4 * (y * w + x), r = random() * 0.04, b = random() * 0.04
            noisy[i] = 0.2 + r; noisy[i + 1] = 0.2 - (0.2126 * r + 0.0722 * b) / 0.7152
            noisy[i + 2] = 0.2 + b
            let colour: Float = x < w / 2 ? 0.3 : -0.1
            edge[i] = 0.3 + colour; edge[i + 1] = 0.3 - 0.2126 * colour / 0.7152; edge[i + 2] = 0.3
            let luma: Float = 0.3 + 0.08 * sin(Float(x) * 1.7) + 0.03 * cos(Float(y) * 0.9)
            texture[i] = luma; texture[i + 1] = luma; texture[i + 2] = luma
            let alpha: Float = x < 4 ? 0 : x < 12 ? 0.2 : 1
            translucent[i] = (y < 4 ? -0.1 : noisy[i]) * alpha
            translucent[i + 1] = noisy[i + 1] * alpha
            translucent[i + 2] = (y < 4 ? 1.3 : noisy[i + 2]) * alpha
            translucent[i + 3] = alpha
            // A saturated warm surface with multiplicative luminance noise:
            // RGB ratios must stay fixed, including at the dark safeguard.
            let gain: Float = y < 4 ? 0.001 : 0.2 + 0.8 * (random() + 0.5)
            warm[i] = 0.7 * gain; warm[i + 1] = 0.35 * gain; warm[i + 2] = 0.008 * gain
        } }
        let source = image(noisy)
        let filtered = pixels(Denoise.apply(source, iso: 6400), ctx)
        let noiseBefore = chromaSD(noisy), noiseAfter = chromaSD(filtered), noiseRatio = noiseAfter / noiseBefore
        let edgeDifference = difference(edge, pixels(Denoise.apply(image(edge), iso: 6400), ctx))
        let textureDifference = difference(texture, pixels(Denoise.apply(image(texture), iso: 6400), ctx))
        let warmDifference = difference(warm, pixels(Denoise.apply(image(warm), iso: 12800), ctx))
        let alphaOutput = pixels(Denoise.apply(image(translucent), iso: 6400), ctx)
        var alphaError = 0.0, lumaError = 0.0
        for i in stride(from: 0, to: translucent.count, by: 4) {
            alphaError = max(alphaError, Double(abs(alphaOutput[i + 3] - translucent[i + 3])))
            let dy = 0.2126 * Double(alphaOutput[i] - translucent[i])
                + 0.7152 * Double(alphaOutput[i + 1] - translucent[i + 1])
                + 0.0722 * Double(alphaOutput[i + 2] - translucent[i + 2])
            lumaError = max(lumaError, abs(dy))
        }
        let nan = difference(noisy, pixels(Denoise.apply(source, iso: 6400, strength: .nan), ctx))
        guard noiseRatio.isFinite, noiseRatio < 0.7,
              (edgeDifference["max"] ?? 1) < 0.0001, (textureDifference["max"] ?? 1) < 0.000001,
              (warmDifference["max"] ?? 1) < 0.000001,
              alphaOutput.allSatisfy(\.isFinite), alphaError < 0.000001, lumaError < 0.000001,
              nan["max"] == 0, !Denoise.isRecommended(iso: nil), !Denoise.isRecommended(iso: 100),
              Denoise.isRecommended(iso: 1600), !Denoise.isRecommended(iso: 6400, isRAW: true),
              Denoise.apply(source, iso: 6400, isRAW: true) === source else {
            throw EngineError.unreadable("denoise synthetic noise / edge / alpha / ISO invariant")
        }

        let folder = out.appendingPathComponent("metadata_fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let cg = ctx.createCGImage(source, from: source.extent) else { throw EngineError.unreadable("ISO fixture pixels") }
        let cases: [(String, [String: Any], Int?)] = [
            ("normal", [kCGImagePropertyExifISOSpeedRatings as String: [3200]], 3200),
            ("overflow", [kCGImagePropertyExifISOSpeedRatings as String: [65535],
                          kCGImagePropertyExifISOSpeed as String: 102400,
                          kCGImagePropertyExifSensitivityType as String: 3], 102400),
            ("missing", [:], nil),
            ("overflow_only", [kCGImagePropertyExifISOSpeedRatings as String: [65535]], nil)
        ]
        var metadata: [String: Any] = [:]
        for (name, exif, expected) in cases {
            let url = folder.appendingPathComponent(name + ".tiff")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
                throw EngineError.unreadable("ISO fixture destination")
            }
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyExifDictionary as String: exif] as CFDictionary)
            guard CGImageDestinationFinalize(dest), Denoise.iso(url) == expected else {
                throw EngineError.unreadable("ISO fixture \(name)")
            }
            metadata[name] = expected as Any? ?? NSNull()
        }
        return ["chroma_std_before": noiseBefore, "chroma_std_after": noiseAfter, "chroma_std_ratio": noiseRatio,
                "clean_colour_edge_difference": edgeDifference, "clean_luminance_texture_difference": textureDifference,
                "constant_warm_chromaticity_luma_noise_difference": warmDifference,
                "max_alpha_error": alphaError, "max_linear_luminance_error": lumaError,
                "nan_strength_difference": nan, "metadata_iso": metadata,
                "note": "96x64 deterministic synthetic fixtures; RGBAf context; equal-luminance colour noise and edge; premultiplied alpha with negative / HDR RGB."]
    }
}
#endif
