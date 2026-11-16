import CoreImage
import simd
import CoreML
import Foundation
import ImageIO

/// One look the model can make. "none" = the neutral render.
struct Look: Identifiable, Hashable {
    static func == (a: Look, b: Look) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    let id: String
    let title: String
    let note: String
    let style: Int?            // the model's expert style (0 = a, 1 = b, 2 = c)
    var grade: (Double, Double, Double, Double) = (0, 0, 0, 0)   // the look's own split toning: shadow hue/strength, highlight hue/strength (0…1)
    var extra: String? = nil     // the Mac's d/e/f: look a plus a colour table fitted on the Mac app's renders (looks/*.cube.bin)
    static let all: [Look] = [      // the Mac's order and words (plugin Config.lua cards)
        Look(id: "none", title: "原片", note: "不调色", style: nil),
        Look(id: "d", title: "自然清透", note: "白里透粉，明亮柔和", style: 0, extra: "d"),
        Look(id: "a", title: "明亮通透", note: "干净偏冷，肤色白皙", style: 0),
        Look(id: "e", title: "韩系", note: "奶白低饱和，柔和", style: 0, grade: (34, 0.12, 212, 0.18), extra: "e"),   // styles.json e extra: strength = saturation × 2
        Look(id: "b", title: "柔和暖调", note: "温暖，低对比", style: 1),
        Look(id: "c", title: "鲜艳浓郁", note: "色彩饱满", style: 2),
        Look(id: "f", title: "港风", note: "浓郁暖调，胶片颗粒", style: 0, grade: (195, 0.35, 45, 0.30), extra: "f"),
        // iPad-only, by recipe on top of a (ipad/scripts/make_extra_luts.py; user 2026-11-15)
        Look(id: "j", title: "日系清新", note: "淡青通透，明亮柔和", style: 0, extra: "j"),
        Look(id: "v", title: "胶片复古", note: "暖调褪色，细腻颗粒", style: 0, extra: "v"),
        Look(id: "m", title: "电影感", note: "青橙对比，暗部偏青", style: 0, extra: "m"),
    ]
}

/// Small corrections, -2 … 2 each: 暗/亮, 冷/暖, 淡/浓. Same meaning as the Mac app's five steps, but stepless.
struct Tweak: Equatable, Hashable {
    var bright = 0.0, warm = 0.0, rich = 0.0     // stepless (user: "滑块给我做无极的")
    var tint = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0   // 绿/粉, 柔/硬, 压/提, 暗/亮 (user: "调色白平衡之类的")
    var skin: SkinPlan? = nil                    // 保留本色 (SkinKeep): this photo's plan for this look, after the tweaks
    var skinMask: SkinOnly.Mask? = nil           // 橙黄只落皮肤 (SkinOnly): where the look's own orange / yellow treatment stays
    var extra: String? = nil                     // the look's own colour table (Look.extra), applied before these
    /// 分区调色 (colour wheels, docs/design/DESIGN.md §7 色盘): hue in degrees, strength 0…1 (shown 0…100)
    var shadowHue = 0.0, shadowSat = 0.0, highlightHue = 0.0, highlightSat = 0.0
    /// where those wheels start: the look's own split toning (DESIGN.md §7 起点和回默认); only the difference is added
    var shadowBaseHue = 0.0, shadowBaseSat = 0.0, highlightBaseHue = 0.0, highlightBaseSat = 0.0
    var shadowMoved: Bool { shadowSat != shadowBaseSat || (shadowSat > 0 && shadowHue != shadowBaseHue) }
    var highlightMoved: Bool { highlightSat != highlightBaseSat || (highlightSat > 0 && highlightHue != highlightBaseHue) }
    var isZero: Bool { bright == 0 && warm == 0 && rich == 0 && tint == 0 && contrast == 0 && highlights == 0 && shadows == 0 && !shadowMoved && !highlightMoved }
    /// The shadow and highlight wheels put at a look's own split toning (untouched wheels follow the look).
    func starting(at look: Look?) -> Tweak {
        var t = self
        let g = look?.grade ?? (0, 0, 0, 0)
        let sMoved = shadowMoved, hMoved = highlightMoved
        (t.shadowBaseHue, t.shadowBaseSat, t.highlightBaseHue, t.highlightBaseSat) = g
        if !sMoved { t.shadowHue = g.0; t.shadowSat = g.1 }
        if !hMoved { t.highlightHue = g.2; t.highlightSat = g.3 }
        return t
    }
    /// Everything back to as the look made it (the wheels to the look's own values).
    var reset: Tweak {
        var t = Tweak()
        (t.shadowBaseHue, t.shadowBaseSat, t.highlightBaseHue, t.highlightBaseSat) = (shadowBaseHue, shadowBaseSat, highlightBaseHue, highlightBaseSat)
        (t.shadowHue, t.shadowSat, t.highlightHue, t.highlightSat) = (shadowBaseHue, shadowBaseSat, highlightBaseHue, highlightBaseSat)
        return t
    }

    var key: String { "\(bright),\(warm),\(rich),\(tint),\(contrast),\(highlights),\(shadows),\(shadowHue),\(shadowSat),\(highlightHue),\(highlightSat)" }
}

/// Retouching for one photo: its faces, what the blemish model proposes (in the rendered picture's pixels), the level.
struct BeautyJob {
    var faces: [Face]
    var edits: [CIImage?]
    var level: BeautyLevel
    var amount: Float = 1            // the strength slider (BeautyLevel.strength k)
    var memo: BeautyMemo? = nil      // measurements kept between renders of this photo and look
    var fullWidth: CGFloat = 0       // width of the full-size picture (0: the rendered one)
    var shape: ShapePlan? = nil      // 塑形 (Shaping.swift): applied last, any size
    var evenLight = false            // 匀光: before the retouching, as on the Mac
}

/// What the model said about one photo and one style: a 33³ colour table and the local tone gains.
struct Grade {
    let cube: Data        // RGBA float, red fastest (CIColorCube order)
    let shadows: Float    // ks
    let highlights: Float // kh
    var flat: Data? = nil // the same table without its own orange / yellow treatment (SkinOnly; only while it is on)
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
            out[style] = Grade(cube: cube.withUnsafeBufferPointer { Data(buffer: $0) }, shadows: t[0], highlights: t[1],
                               flat: SkinOnly.on ? SkinOnly.flatten(cube, D)?.withUnsafeBufferPointer { Data(buffer: $0) } : nil)
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
        kernel vec4 g(__sample i, vec3 gain, float sat, vec3 m0, vec3 m1, vec3 m2) {
          vec3 c = max(i.rgb, 0.0) * gain;
          c = c + vec3(dot(m0, c), dot(m1, c), dot(m2, c));     // 绿粉: the channels moved into one another (a table)
          float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
          return vec4(max(y + sat * (c - y), 0.0), i.a);
        }
        """)!
    /// 绿粉 per unit on linear sRGB, out = in + T x (table x in); rows give R, G, B (DESIGN.md §7, second version)
    private static let tintTable: [SIMD3<Float>] = [[0.0569, -0.0633, 0.0079], [-0.0236, 0.0646, -0.0435], [-0.0019, 0.0684, -0.0492]]
    /// 分区调色 (DESIGN.md §7, second version): each channel moves by shape(its own sRGB value) x factor, factor = table x
    /// the hue's pure colour x strength; rows give R, G, B
    private static let shadowTable: [SIMD3<Double>] = [[0.1148, -0.1184, -0.0127], [-0.0529, 0.049, -0.0017], [-0.029, -0.0831, 0.0996]]
    private static let highTable: [SIMD3<Double>] = [[0.106, -0.1039, -0.0093], [-0.0554, 0.0542, -0.0008], [-0.0278, -0.0866, 0.1183]]
    private static let splitTone = CIColorKernel(source: """
          float sh(float v) { float a = clamp(v, 0.0, 1.0) * 24.0; return 0.673*max(0.0,1.0-abs(a-0.0)) + 0.775*max(0.0,1.0-abs(a-1.0)) + 0.908*max(0.0,1.0-abs(a-2.0)) + 0.999*max(0.0,1.0-abs(a-3.0)) + 0.983*max(0.0,1.0-abs(a-4.0)) + 1.0*max(0.0,1.0-abs(a-5.0)) + 0.972*max(0.0,1.0-abs(a-6.0)) + 0.898*max(0.0,1.0-abs(a-7.0)) + 0.793*max(0.0,1.0-abs(a-8.0)) + 0.694*max(0.0,1.0-abs(a-9.0)) + 0.59*max(0.0,1.0-abs(a-10.0)) + 0.501*max(0.0,1.0-abs(a-11.0)) + 0.426*max(0.0,1.0-abs(a-12.0)) + 0.365*max(0.0,1.0-abs(a-13.0)) + 0.315*max(0.0,1.0-abs(a-14.0)) + 0.275*max(0.0,1.0-abs(a-15.0)) + 0.24*max(0.0,1.0-abs(a-16.0)) + 0.204*max(0.0,1.0-abs(a-17.0)) + 0.17*max(0.0,1.0-abs(a-18.0)) + 0.135*max(0.0,1.0-abs(a-19.0)) + 0.104*max(0.0,1.0-abs(a-20.0)) + 0.076*max(0.0,1.0-abs(a-21.0)) + 0.051*max(0.0,1.0-abs(a-22.0)) + 0.025*max(0.0,1.0-abs(a-23.0)) + 0.01*max(0.0,1.0-abs(a-24.0)); }
          float hi(float v) { float a = clamp(v, 0.0, 1.0) * 24.0; return 0.01*max(0.0,1.0-abs(a-0.0)) + 0.011*max(0.0,1.0-abs(a-1.0)) + 0.014*max(0.0,1.0-abs(a-2.0)) + 0.022*max(0.0,1.0-abs(a-3.0)) + 0.03*max(0.0,1.0-abs(a-4.0)) + 0.051*max(0.0,1.0-abs(a-5.0)) + 0.081*max(0.0,1.0-abs(a-6.0)) + 0.111*max(0.0,1.0-abs(a-7.0)) + 0.139*max(0.0,1.0-abs(a-8.0)) + 0.177*max(0.0,1.0-abs(a-9.0)) + 0.221*max(0.0,1.0-abs(a-10.0)) + 0.258*max(0.0,1.0-abs(a-11.0)) + 0.306*max(0.0,1.0-abs(a-12.0)) + 0.377*max(0.0,1.0-abs(a-13.0)) + 0.457*max(0.0,1.0-abs(a-14.0)) + 0.551*max(0.0,1.0-abs(a-15.0)) + 0.649*max(0.0,1.0-abs(a-16.0)) + 0.759*max(0.0,1.0-abs(a-17.0)) + 0.856*max(0.0,1.0-abs(a-18.0)) + 0.953*max(0.0,1.0-abs(a-19.0)) + 1.0*max(0.0,1.0-abs(a-20.0)) + 0.972*max(0.0,1.0-abs(a-21.0)) + 0.867*max(0.0,1.0-abs(a-22.0)) + 0.611*max(0.0,1.0-abs(a-23.0)) + 0.403*max(0.0,1.0-abs(a-24.0)); }
          kernel vec4 s(__sample c, vec3 fs, vec3 fh) {
            vec3 v = c.rgb;
            vec3 o = v + vec3(sh(v.r), sh(v.g), sh(v.b)) * fs + vec3(hi(v.r), hi(v.g), hi(v.b)) * fh;
            return vec4(o, c.a);
          }
        """)!
    private static let contrast = CIColorKernel(source:
        "kernel vec4 k(__sample i, float c) { return vec4(clamp(0.5 + c * (i.rgb - 0.5), 0.0, 1.0), i.a); }")!

    /// The Mac's looks d/e/f on top of look a: a colour table on sRGB numbers (fitted by ipad/scripts/fit_style_lut.py
    /// from the Mac app's own renders), and for 港风 the vignette and film grain Lightroom adds (styles.json f).
    private static var cubes: [String: Data] = [:]
    private static let cubeLock = NSLock()
    private static func cube(_ name: String, flat: Bool = false) -> Data? {
        cubeLock.lock(); defer { cubeLock.unlock() }
        let key = flat ? name + "~flat" : name
        if let d = cubes[key] { return d }
        guard let u = Bundle.main.url(forResource: name + ".cube", withExtension: "bin"), let d = try? Data(contentsOf: u) else { return nil }
        cubes[name] = d
        if flat { let f = SkinOnly.flatten(d, 17) ?? d; cubes[key] = f; return f }     // the look's own orange / yellow part too (main session 2026-11-16)
        return d
    }
    private static let grain = CIColorKernel(source: """
        kernel vec4 grain(__sample c, __sample n, float amount) {
            float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
            float g = (n.r - 0.5) * amount * 4.0 * l * (1.0 - l);      // strongest in the mid-tones, as film
            return vec4(clamp(c.rgb + g, 0.0, 1.0), c.a);
        }
        """)!
    private func finish(_ image: CIImage, _ name: String, flat: Bool = false) -> CIImage {
        let e = image.extent
        guard let data = Self.cube(name, flat: flat) else { return image }
        var enc = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 17, "inputCubeData": data])
        if name == "f" || name == "v" {
            let w = Double(max(e.width, e.height))
            // vignette (PostCropVignetteAmount -12): a soft darkening towards the corners
            let ring = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: e.midX, y: e.midY), "inputRadius0": 0.35 * w, "inputRadius1": 0.75 * w,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0.9, green: 0.9, blue: 0.9)])!.outputImage!
            enc = enc.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ring.cropped(to: e)])
            // grain (GrainAmount 28, size 20): grain a fixed share of the picture, so preview and export look alike
            let cell = max(1, w / 2600)
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell)).applyingGaussianBlur(sigma: 0.6 * cell)
                .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).cropped(to: e)
            enc = Self.grain.apply(extent: e, arguments: [enc, noise, Float(name == "v" ? 0.035 : 0.045)]) ?? enc
        }
        return enc.cropped(to: e).applyingFilter("CISRGBToneCurveToLinear")
    }

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
            let toned = img
            func colour(_ cube: Data, flat: Bool) -> CIImage {
                let c = toned.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": Self.D, "inputCubeData": cube, "inputColorSpace": srgb])
                return tweak.extra.map { finish(c, $0, flat: flat) } ?? c
            }
            img = colour(g.cube, flat: false)
            if let m = tweak.skinMask, let f = g.flat {
                // 橙黄只落皮肤 (SkinOnly): the look as made on the skin, without its orange / yellow treatment elsewhere
                img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: colour(f, flat: true), kCIInputMaskImageKey: m.over(extent)])
                    .cropped(to: extent)
            }
        } else if let x = tweak.extra { img = finish(img, x) }
        // the built-in looks a little darker than the experts' (user: "default a little too bright"; Mac: predict.BRIGHT)
        let ev: Float = grade == nil ? 0 : Self.bright
        if !tweak.isZero || ev != 0 {
            let (b, w, r) = (Float(tweak.bright), Float(tweak.warm), Float(tweak.rich))
            let t = Float(tweak.tint)       // + = pink (magenta), - = green: the other half of white balance
            // DESIGN.md §7 即时近似 (fitted to Lightroom, the same numbers on every platform)
            let gain = CIVector(x: CGFloat(powf(2, ev + 0.162 * b + 0.070 * w - 0.012 * r)),
                                y: CGFloat(powf(2, ev + 0.158 * b + 0.026 * w - 0.012 * r)),
                                z: CGFloat(powf(2, ev + 0.150 * b - 0.025 * w - 0.013 * r)))
            let m = Self.tintTable.map { CIVector(x: CGFloat($0.x * t), y: CGFloat($0.y * t), z: CGFloat($0.z * t)) }
            img = Self.tweakGain.apply(extent: extent, arguments: [img, gain, 1 + 0.095 * r, m[0], m[1], m[2]])!
            let c = 1 - 0.055 * b + 0.016 * r + 0.10 * Float(tweak.contrast)
            var enc = Self.contrast.apply(extent: extent, arguments: [img.applyingFilter("CILinearToSRGBToneCurve"), c])!
            if tweak.highlights != 0 || tweak.shadows != 0 {
                // 高光 压/提 and 阴影 暗/亮: Core Image's local highlight/shadow tool (it keeps local contrast)
                enc = enc.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 1 - 0.25 * max(0, -tweak.highlights),
                    "inputShadowAmount": 0.25 * tweak.shadows,
                    "inputRadius": 0.01 * Double(max(extent.width, extent.height))]).cropped(to: extent)
                if tweak.highlights > 0 { enc = Self.contrast.apply(extent: extent, arguments: [enc, Float(1)])! }      // (lifting highlights: the gain below)
            }
            if tweak.shadowMoved || tweak.highlightMoved {
                // 分区调色 (DESIGN.md §7 即时近似, second version): the wheels start at the look's own values, so the
                // factors of (new − the look's own) are laid on
                func f(_ h: Double, _ k: Double, _ table: [SIMD3<Double>]) -> SIMD3<Double> {
                    let r = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60, x = 1 - abs(r.truncatingRemainder(dividingBy: 2) - 1)
                    let c: SIMD3<Double> = r < 1 ? [1, x, 0] : r < 2 ? [x, 1, 0] : r < 3 ? [0, 1, x] : r < 4 ? [0, x, 1] : r < 5 ? [x, 0, 1] : [1, 0, x]
                    return SIMD3(table.map { ($0 * c).sum() * k })        // k: strength 0…1 = amount / 100
                }
                let us = tweak.shadowMoved ? f(tweak.shadowHue, tweak.shadowSat, Self.shadowTable) - f(tweak.shadowBaseHue, tweak.shadowBaseSat, Self.shadowTable) : .zero
                let uh = tweak.highlightMoved ? f(tweak.highlightHue, tweak.highlightSat, Self.highTable) - f(tweak.highlightBaseHue, tweak.highlightBaseSat, Self.highTable) : .zero
                enc = Self.splitTone.apply(extent: extent, arguments: [enc, CIVector(x: us.x, y: us.y, z: us.z), CIVector(x: uh.x, y: uh.y, z: uh.z)])!
            }
            img = enc.applyingFilter("CISRGBToneCurveToLinear")
            if tweak.highlights > 0 {
                img = Self.tweakGain.apply(extent: extent, arguments: [img, CIVector(x: 1 + 0.06 * tweak.highlights, y: 1 + 0.06 * tweak.highlights, z: 1 + 0.06 * tweak.highlights), Float(1), CIVector(x: 0, y: 0, z: 0), CIVector(x: 0, y: 0, z: 0), CIVector(x: 0, y: 0, z: 0)])!
            }
        }
        if let sp = tweak.skin { img = SkinKeep.apply(img, sp) }
        // retouching last, on sRGB numbers, as the Mac pipeline does on Lightroom's export
        if let b = beauty, !b.faces.isEmpty, b.level != .off || b.evenLight {
            var enc = img.cropped(to: extent).applyingFilter("CILinearToSRGBToneCurve")
            if b.evenLight { enc = Shaping.evenLight(enc, faces: b.faces, amount: ShapeSet.amount["light"]!, context: context) }
            if b.level != .off {
                enc = Beauty.shared.apply(enc, faces: b.faces, edits: b.edits, level: b.level, amount: b.amount, memo: b.memo, fullWidth: b.fullWidth)
            }
            img = enc.applyingFilter("CISRGBToneCurveToLinear")
        }
        if let plan = beauty?.shape { img = Shaping.apply(img.cropped(to: extent), plan) }     // geometry last (beautify.geometry)
        return img.cropped(to: extent)
    }

    /// Self-test only (LRCDF_DEBUG): footprint now and the peak so far, in MB.
    /// Runs `work` on a thread of its own with a 64 MB stack. Core Image renders the graph of a group photo
    /// recursively; with 29 faces that went deeper than the 512 KB stack of Swift's task threads on the iPad and the
    /// app crashed (stack guard, 2026-11-15, first test on the user's iPad). The Mac's threads had hidden it.
    static func bigStack<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let t = Thread { c.resume(returning: work()) }
            t.stackSize = 64 << 20; t.qualityOfService = .userInitiated; t.start()
        }
    }

    /// LRCDF_TIME: seconds since the previous lap, for finding what makes opening a photo slow.
    nonisolated(unsafe) private static var lastLap = Date()
    static func lap(_ what: String) {
        guard Beauty.testEnv["LRCDF_TIME"] != nil else { return }
        print(String(format: "  time %@: %.2fs", what, -lastLap.timeIntervalSinceNow)); lastLap = Date()
    }

    static func mem(_ what: String) {
        let env = Beauty.testEnv
        guard env["LRCDF_DEBUG"] != nil || env["LRCDF_MEM"] != nil else { return }
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        #if os(iOS)
        let left = Int(os_proc_available_memory() / 1_000_000)     // what iOS still allows this app before stopping it
        #else
        let left = -1
        #endif
        print(String(format: "  mem %@: now %d MB, peak %d MB, left %d MB", what, Int(info.phys_footprint / 1_000_000), Int(info.ledger_phys_footprint_peak / 1_000_000), left))
    }

    /// The image rendered into memory (half float, working space), a band of rows at a time.
    nonisolated(unsafe) static var stripRows = Int(Beauty.testEnv["LRCDF_STRIP"] ?? "") ?? 512
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
    func export(_ url: URL, grade: Grade?, tweak: Tweak, denoise: (iso: Int?, isRAW: Bool)? = nil, faces: [Face] = [], level: BeautyLevel = .off, amount: Float = 1, memo: BeautyMemo? = nil,
                shape: ShapePlan? = nil, evenLight: Bool = false, to folder: URL) throws -> URL {
        // Memory (the iPad allows an app about 4 GB): the RAW is decoded once into a half-float buffer, and the
        // finished picture is rendered into a second one in strips, so Core Image never holds the intermediates of
        // the whole 60 MP graph at once. Strips give the same pixels as one render (each strip reads what it needs).
        context.clearCaches(); Beauty.shared.context.clearCaches()
        // a context of its own: what the GPU kept for this picture goes when the export ends
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        Self.mem("start")
        // the decoded original lives only inside this block: it is let go before the file is written
        let out: CIImage = try autoreleasepool {
            // 降噪 first, at full resolution, inside the same strip pass as the decode (Denoise.swift: no second full buffer)
            let decoded = try decode(url, maxSide: nil)
            let full = try strips(denoise.map { Denoise.apply(decoded, iso: $0.iso, isRAW: $0.isRAW) } ?? decoded, context: ctx)
            context.clearCaches()
            Self.mem("decoded")
            var job: BeautyJob? = shape != nil || evenLight ? BeautyJob(faces: faces, edits: [], level: .off, shape: shape, evenLight: evenLight) : nil
            if level != .off, !faces.isEmpty {     // the blemish model again, on the full-size faces
                job = BeautyJob(faces: faces, edits: Beauty.shared.edits(full, faces: faces, fullWidth: full.extent.width), level: level,
                               amount: amount, memo: memo?.keeping(["body"]),     // the body skin plan of the preview (size-independent); noise and the guard are measured again
                               shape: shape, evenLight: evenLight)
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
