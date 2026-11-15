import CoreImage
import CoreML
import Foundation
import ImageIO

/// One look the model can make. "none" = the neutral render.
struct Look: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String
    let style: Int?            // the model's expert style (0 = a, 1 = b, 2 = c)
    static let all: [Look] = [
        Look(id: "none", title: "原片", note: "不调色", style: nil),
        Look(id: "a", title: "明亮通透", note: "干净偏冷，肤色白皙", style: 0),
        Look(id: "b", title: "柔和暖调", note: "温暖，低对比", style: 1),
        Look(id: "c", title: "鲜艳浓郁", note: "色彩饱满", style: 2),
    ]
}

/// Small corrections in five steps each (-2 … 2): 暗/亮, 冷/暖, 淡/浓. Same meaning as the Mac app.
struct Tweak: Equatable, Hashable {
    var bright = 0, warm = 0, rich = 0
    var isZero: Bool { bright == 0 && warm == 0 && rich == 0 }
}

/// Retouching for one photo: its faces, what the blemish model proposes (in the rendered picture's pixels), the level.
struct BeautyJob {
    var faces: [Face]
    var edits: [CIImage?]
    var level: BeautyLevel
    var memo: BeautyMemo? = nil      // measurements kept between renders of this photo and look
    var fullWidth: CGFloat = 0       // width of the full-size picture (0: the rendered one)
}

/// What the model said about one photo and one style: a 33³ colour table and the local tone gains.
struct Grade {
    let cube: Data        // RGBA float, red fastest (CIColorCube order)
    let shadows: Float    // ks
    let highlights: Float // kh
}

enum EngineError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let n): return "打不开这张照片：\(n)" }
    }
}

/// Decoding, the tone model and rendering. Everything is Core Image + Core ML: no Lightroom, no network.
final class Engine: @unchecked Sendable {
    static let shared = Engine()
    let context: CIContext
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let model: MLModel?
    static let D = 33
    static let bright: Float = -0.22

    private init() {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      .cacheIntermediates: false])
        let config = MLModelConfiguration(); config.computeUnits = .all
        if let url = ModelStore.url("LUTNet2") {      // an update in the container wins (Updater.swift)
            model = try? MLModel(contentsOf: url, configuration: config)
        } else { model = nil }
    }

    var modelReady: Bool { model != nil }

    // MARK: decoding

    /// The picture as Lightroom would show it before any edit: RAW through Apple's newest decoder (RAW 9: AI
    /// demosaic + denoise), anything else as it is. `maxSide` = nil for full size.
    func decode(_ url: URL, maxSide: CGFloat?) throws -> CIImage {
        if let raw = CIRAWFilter(imageURL: url), !raw.supportedDecoderVersions.isEmpty {
            if let newest = raw.supportedDecoderVersions.last { raw.decoderVersion = newest }
            let native = raw.nativeSize
            if let side = maxSide, max(native.width, native.height) > side {
                raw.scaleFactor = Float(side / max(native.width, native.height))
            }
            if let img = raw.outputImage { return img }
        }
        guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw EngineError.unreadable(url.lastPathComponent)
        }
        if let side = maxSide, max(img.extent.width, img.extent.height) > side {
            let s = side / max(img.extent.width, img.extent.height)
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    /// Width of the full-size decode (cheap: nothing is decoded until rendered).
    func fullWidth(_ url: URL) -> CGFloat? { (try? decode(url, maxSide: nil))?.extent.width }

    // MARK: the tone model

    /// Runs the model once per style on a 256×256 copy (sRGB-encoded values, like PPR10K's sources).
    func grades(for image: CIImage) throws -> [Int: Grade] {
        guard let model else { return [:] }
        let n = 256
        let e = image.extent
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(n) / e.width, y: CGFloat(n) / e.height))
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        var px = [Float](repeating: 0, count: n * n * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(small, toBitmap: buf.baseAddress!, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                           format: .RGBAf, colorSpace: srgb)
        }
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<n { for x in 0..<n { for c in 0..<3 {
            ptr[c * n * n + y * n + x] = min(max(px[(y * n + x) * 4 + c], 0), 1)
        } } }
        var out: [Int: Grade] = [:]
        for style in 0..<3 {
            let st = try MLMultiArray(shape: [1], dataType: .int32); st[0] = NSNumber(value: style)
            let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input, "style": st]))
            guard let lut = res.featureValue(for: "lut")?.multiArrayValue,
                  let tone = res.featureValue(for: "tone")?.multiArrayValue else { continue }
            let l = MLShapedArray<Float>(converting: lut).scalars       // [c][b][g][r]
            let t = MLShapedArray<Float>(converting: tone).scalars
            let D = Self.D, vol = D * D * D
            var cube = [Float](repeating: 1, count: vol * 4)
            for i in 0..<vol { for c in 0..<3 { cube[i * 4 + c] = min(max(l[c * vol + i], 0), 1) } }
            out[style] = Grade(cube: cube.withUnsafeBufferPointer { Data(buffer: $0) }, shadows: t[0], highlights: t[1])
        }
        return out
    }

    // MARK: rendering

    private static let luminance = CIColorKernel(source:
        "kernel vec4 l(__sample i) { float m = (i.r + i.g + i.b) / 3.0; return vec4(m, m, m, 1.0); }")!
    private static let localTone = CIColorKernel(source: """
        kernel vec4 t(__sample i, __sample b, float ks, float kh) {
          float ws = pow(clamp(1.0 - b.r / 0.5, 0.0, 1.0), 2.0);
          float wh = pow(clamp((b.r - 0.5) / 0.5, 0.0, 1.0), 2.0);
          return vec4(clamp(i.rgb * exp(ks * ws + kh * wh), 0.0, 1.0), i.a);
        }
        """)!
    /// 暗/亮, 冷/暖, 淡/浓 in linear light; numbers fitted to Lightroom's renders (see the Mac app's Quick.swift).
    private static let tweakGain = CIColorKernel(source: """
        kernel vec4 g(__sample i, vec3 gain, float sat) {
          vec3 c = max(i.rgb, 0.0) * gain;
          float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
          return vec4(max(y + sat * (c - y), 0.0), i.a);
        }
        """)!
    private static let contrast = CIColorKernel(source:
        "kernel vec4 k(__sample i, float c) { return vec4(clamp(0.5 + c * (i.rgb - 0.5), 0.0, 1.0), i.a); }")!

    /// The finished picture: local tone → colour table → tweaks. Works at any size (preview or full).
    func render(_ image: CIImage, grade: Grade?, tweak: Tweak, beauty: BeautyJob? = nil) -> CIImage {
        var img = image
        let extent = image.extent
        if let g = grade {
            // the model saw sRGB-encoded numbers: work on those for the local tone step
            let enc = img.applyingFilter("CILinearToSRGBToneCurve")
            if abs(g.shadows) > 1e-4 || abs(g.highlights) > 1e-4 {
                let lum = Self.luminance.apply(extent: extent, arguments: [enc])!
                let sigma = 0.04 * Double(min(extent.width, extent.height))
                let base = lum.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
                let toned = Self.localTone.apply(extent: extent, arguments: [enc, base, g.shadows, g.highlights])!
                img = toned.applyingFilter("CISRGBToneCurveToLinear")
            }
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": Self.D, "inputCubeData": g.cube, "inputColorSpace": srgb])
        }
        // the built-in looks a little darker than the experts' (user: "default a little too bright"; Mac: predict.BRIGHT)
        let ev: Float = grade == nil ? 0 : Self.bright
        if !tweak.isZero || ev != 0 {
            let (b, w, r) = (Float(tweak.bright), Float(tweak.warm), Float(tweak.rich))
            let gain = CIVector(x: CGFloat(powf(2, ev + 0.162 * b + 0.070 * w - 0.012 * r)),
                                y: CGFloat(powf(2, ev + 0.158 * b + 0.026 * w - 0.012 * r)),
                                z: CGFloat(powf(2, ev + 0.150 * b - 0.025 * w - 0.013 * r)))
            img = Self.tweakGain.apply(extent: extent, arguments: [img, gain, 1 + 0.095 * r])!
            let c = 1 - 0.055 * b + 0.016 * r
            img = Self.contrast.apply(extent: extent, arguments: [img.applyingFilter("CILinearToSRGBToneCurve"), c])!
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        // retouching last, on sRGB numbers, as the Mac pipeline does on Lightroom's export
        if let b = beauty, b.level != .off, !b.faces.isEmpty {
            let enc = img.cropped(to: extent).applyingFilter("CILinearToSRGBToneCurve")
            img = Beauty.shared.apply(enc, faces: b.faces, edits: b.edits, level: b.level, memo: b.memo, fullWidth: b.fullWidth).applyingFilter("CISRGBToneCurveToLinear")
        }
        return img.cropped(to: extent)
    }

    /// Self-test only (LRCDF_DEBUG): footprint now and the peak so far, in MB.
    static func mem(_ what: String) {
        guard ProcessInfo.processInfo.environment["LRCDF_DEBUG"] != nil else { return }
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        print(String(format: "  mem %@: now %d MB, peak %d MB", what, Int(info.phys_footprint / 1_000_000), Int(info.ledger_phys_footprint_peak / 1_000_000)))
    }

    /// The image rendered into memory (half float, working space), a band of rows at a time.
    nonisolated(unsafe) static var stripRows = Int(ProcessInfo.processInfo.environment["LRCDF_STRIP"] ?? "") ?? 512
    func strips(_ image: CIImage, context: CIContext? = nil) throws -> CIImage {
        let context = context ?? self.context
        let e = image.extent.integral, w = Int(e.width), h = Int(e.height)
        let rowBytes = w * 8
        guard let mem = malloc(rowBytes * h) else { throw EngineError.unreadable("memory") }
        var y = 0
        while y < h {
            let n = min(Self.stripRows, h - y)
            // bitmap rows run top-down; Core Image's y runs up: rows y..y+n from the top = CI band h-y-n ..< h-y
            let band = CGRect(x: e.minX, y: e.minY + CGFloat(h - y - n), width: CGFloat(w), height: CGFloat(n))
            autoreleasepool {
                context.render(image, toBitmap: mem + y * rowBytes, rowBytes: rowBytes, bounds: band, format: .RGBAh, colorSpace: nil)
            }
            y += n
        }
        let data = Data(bytesNoCopy: mem, count: rowBytes * h, deallocator: .free)
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)
    }

    // MARK: export

    /// Full-size render written as 10-bit HEIC (Display P3) next to nothing else; returns the file.
    func export(_ url: URL, grade: Grade?, tweak: Tweak, faces: [Face] = [], level: BeautyLevel = .off, memo: BeautyMemo? = nil, to folder: URL) throws -> URL {
        // Memory (the iPad allows an app about 4 GB): the RAW is decoded once into a half-float buffer, and the
        // finished picture is rendered into a second one in strips, so Core Image never holds the intermediates of
        // the whole 60 MP graph at once. Strips give the same pixels as one render (each strip reads what it needs).
        context.clearCaches(); Beauty.shared.context.clearCaches()
        // a context of its own: what the GPU kept for this picture goes when the export ends
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        Self.mem("start")
        // the decoded original lives only inside this block: it is let go before the file is written
        let out: CIImage = try autoreleasepool {
            let full = try strips(decode(url, maxSide: nil), context: ctx)
            context.clearCaches()
            Self.mem("decoded")
            var job: BeautyJob? = nil
            if level != .off, !faces.isEmpty {     // the blemish model again, on the full-size faces
                job = BeautyJob(faces: faces, edits: Beauty.shared.edits(full, faces: faces, fullWidth: full.extent.width), level: level,
                               memo: memo?.keeping(["body"]))     // the body skin plan of the preview (size-independent); noise and the guard are measured again
            }
            context.clearCaches(); Beauty.shared.context.clearCaches()
            Self.mem("edits")
            return try strips(render(full, grade: grade, tweak: tweak, beauty: job), context: ctx)
        }
        context.clearCaches(); Beauty.shared.context.clearCaches()
        Self.mem("rendered")
        let name = url.deletingPathExtension().lastPathComponent + "-一键修图.heic"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try ctx.writeHEIF10Representation(of: out, to: dest, colorSpace: displayP3,
                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
        Self.mem("written")
        return dest
    }
}
