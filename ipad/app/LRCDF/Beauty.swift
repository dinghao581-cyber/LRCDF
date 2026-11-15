import Accelerate
import CoreImage
import CoreML
import Foundation
import Vision

/// How much retouching: the Mac app's levels (plug-in Config.beautyLevels), in beauty.py's units.
enum BeautyLevel: String, CaseIterable, Identifiable {
    case off, natural, refined
    var id: String { rawValue }
    var title: String { switch self { case .off: "不修"; case .natural: "自然"; case .refined: "精致" } }
    var note: String { switch self { case .off: "保持原样"; case .natural: "去痘匀肤，看不出修过"; case .refined: "更干净细腻" } }
    var strength: Strength? {
        switch self {
        case .off: nil
        case .natural: Strength(blemish: 1.0, smooth: 0.60, undereye: 0.50, eyes: 0.40, teeth: 0.40)
        case .refined: Strength(blemish: 1.2, smooth: 0.85, undereye: 0.70, eyes: 0.55, teeth: 0.55)
        }
    }
}

struct Strength {
    var blemish, smooth, undereye, eyes, teeth: Float
    var skip: Set<String> = Set((ProcessInfo.processInfo.environment["LRCDF_SKIP"] ?? "").split(separator: ",").map(String.init))   // self-test only
    var spots: Float { skip.contains("spots") ? 0 : blemish }     // beauty.DEFAULTS spots 1.0 × level
    var shine: Float { skip.contains("shine") ? 0 : 0.5 * min(1.6, smooth / 0.6) }             // follows the level (beautify.retouch)
}

/// One face as Vision found it. Points are normalised to the picture (0…1, origin bottom-left, like Core Image),
/// so the same face serves the preview and the full-size picture.
struct Face {
    var box: CGRect
    var eyeL: [CGPoint], eyeR: [CGPoint], browL: [CGPoint], browR: [CGPoint]
    var lipsOut: [CGPoint], lipsIn: [CGPoint]
    /// Five points: eye on the picture's left, the other eye, nose, mouth corners (left, right). Always present.
    var points: [CGPoint]
    /// false: only the detector's box and five points (strong profile, cheek close-up): skin is still evened and marks
    /// corrected, eyes and mouth are left alone, the under-eye/eye/teeth steps are skipped (beauty.beautify_face).
    var mesh: Bool
    var width: CGFloat           // face width, normalised to the picture width (jaw outline or box)
    var area: CGRect             // where the skin map lies (normalised)
    var skin: CIImage?           // 256×256 face + body skin confidence (MediaPipe's selfie multiclass), over `area`
    var nose: [CGPoint] = []     // lower nose outline (Vision): the nostrils are not wrinkles
    var makeup: Float = 0        // 0 bare … 1 made-up (Beauty.makeupScore): how much the make-up-safe rules apply
}

/// Portrait retouching by frequency separation (高低频), ported from the Mac pipeline (lrcdf/beauty.py,
/// scripts/beautify.py). Skin = low layer (colour and light, evened) + high layer (texture, kept except on
/// blemishes). Everything is built as a Core Image graph whose sizes follow the face width in pixels, so the
/// preview and the full-size export get the same result at their own resolution.
final class Beauty: @unchecked Sendable {
    static let shared = Beauty()
    private let seg: MLModel?
    // the face detector (RetinaFace) and the blemish model (RetouchNet) are loaded when needed and let go after:
    // kept loaded they hold about 1.2 GB that the full-size export needs (the iPad allows an app about 4 GB)
    private let config: MLModelConfiguration
    private let critic: MLModel?
    let context: CIContext

    // beauty.py constants
    static let SPLIT: CGFloat = 0.006, HEAL: Float = 0.7, RELIEF: Float = 0.8, RELIEF_REACH: Float = 3.0
    static let SPOT_WIDTH: CGFloat = 0.06
    static let WRINKLES: CGFloat = 0.5, UNIFY: Float = 0,   // UNIFY: the Mac never applies it (beauty.beautify_body only marks the cheeks of people left alone, so its test fails); 0 = the same here
                 BODY: CGFloat = 0.75
    static let LINES: (Float, Float, Float, Float) = (0.012, 0.03, 0.11, 0.17), LINE_SCALE: CGFloat = 360, LINE_WIDTH: CGFloat = 0.035
    static let HAIR: (Float, Float) = (0.012, 0.03), HAIR_SCALE: CGFloat = 400
    static let TEXTURE_LIMIT: Float = 1.4, COLOUR_LIMIT: (Float, Float) = (2.0, 2.1)

    private init() {
        config = MLModelConfiguration(); config.computeUnits = .all
        seg = Self.load("SelfieSeg", config); critic = Self.load("Critic", config)
        context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    }
    private static func load(_ n: String, _ config: MLModelConfiguration) -> MLModel? {
        ModelStore.url(n).flatMap { try? MLModel(contentsOf: $0, configuration: config) }      // an update in the container wins (Updater.swift)
    }
    var ready: Bool { seg != nil && ModelStore.url("RetouchNet") != nil }
    /// Self-test only: intermediate images of each face are written here.
    nonisolated(unsafe) static var debugDir: URL?
    nonisolated(unsafe) static var debugName = ""
    private var debugFace = 0
    private func dump(_ name: String, _ i: CIImage, gain: CGFloat = 1, offset: CGFloat = 0) {
        guard let d = Beauty.debugDir else { return }
        let v = K.lin.apply(extent: i.extent, arguments: [i, gain, offset])!
        try? Engine.shared.context.writePNGRepresentation(of: v, to: d.appendingPathComponent("\(Beauty.debugName)_f\(debugFace)_\(name).png"), format: .RGBA8, colorSpace: Engine.shared.srgb)
    }

    // MARK: finding faces (once per photo, on the preview)

    /// Faces with their landmarks and skin map. `image`: the decoded picture (linear, as Engine.decode gives it).
    func faces(in image: CIImage) -> [Face] {
        let e = image.extent
        guard let cg = Engine.shared.context.createCGImage(image, from: e, format: .RGBA8, colorSpace: Engine.shared.srgb) else { return [] }
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
        let W = e.width, H = e.height
        let srgbImage = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])      // sRGB-encoded numbers
        var out: [Face] = []
        for o in (req.results ?? []) where o.confidence > 0.5 {
            guard let lm = o.landmarks, let le = lm.leftEye, let re = lm.rightEye, let lo = lm.outerLips else { continue }
            func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (r?.pointsInImage(imageSize: CGSize(width: W, height: H)) ?? []).map { CGPoint(x: $0.x / W, y: $0.y / H) }
            }
            let box = o.boundingBox
            var width = box.width
            if let c = lm.faceContour { let p = pts(c); if let a = p.map(\.x).min(), let b = p.map(\.x).max() { width = max(width, b - a) } }
            if width * W < 24 { continue }                   // too small to retouch
            let mid = { (p: [CGPoint]) -> CGPoint in CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(max(p.count, 1)), y: p.map(\.y).reduce(0, +) / CGFloat(max(p.count, 1))) }
            let lips = pts(lo)
            var eyes = [mid(pts(le)), mid(pts(re))].sorted { $0.x < $1.x }
            let corners = [lips.min { $0.x < $1.x } ?? .zero, lips.max { $0.x < $1.x } ?? .zero]
            eyes += [mid(pts(lm.nose))] + corners
            out.append(Face(box: box, eyeL: pts(le), eyeR: pts(re), browL: pts(lm.leftEyebrow), browR: pts(lm.rightEyebrow),
                            lipsOut: lips, lipsIn: pts(lm.innerLips), points: eyes, mesh: true, width: width, area: .zero, skin: nil, nose: pts(lm.nose)))
        }
        // faces Vision does not see (strong profiles, close-ups of a cheek): the Mac pipeline's detector, box + 5 points
        for d in retina(srgbImage) {
            let c = CGPoint(x: d.box.midX, y: d.box.midY)
            if out.contains(where: { $0.box.insetBy(dx: -0.25 * $0.box.width, dy: -0.25 * $0.box.height).contains(c) }) { continue }
            if d.box.width * W < 24 { continue }
            out.append(Face(box: d.box, eyeL: [], eyeR: [], browL: [], browR: [], lipsOut: [], lipsIn: [], points: d.points,
                            mesh: false, width: d.box.width, area: .zero, skin: nil))
        }
        for i in out.indices {
            // the skin map: the face box widened by 0.6 of its size each way (beauty.beautify's crop)
            let box = out[i].box
            let px = CGRect(x: box.minX * W, y: box.minY * H, width: box.width * W, height: box.height * H)
            let m = 0.6 * max(px.width, px.height)
            let area = px.insetBy(dx: -m, dy: -m).intersection(e).integral
            out[i].area = CGRect(x: area.minX / W, y: area.minY / H, width: area.width / W, height: area.height / H)
            out[i].skin = skinMap(srgbImage, area)
        }
        // make-up: one score per face (MobileCLIP2-S2, zero-shot "made-up face" vs "bare face"); loaded only for this
        if let mm = Self.load("Makeup", config) {
            for i in out.indices {
                let sc = makeupScore(srgbImage, out[i].box, mm)
                out[i].makeup = min(max((sc + 0.4) / 0.7, 0), 1)
                if Beauty.debugDir != nil || ProcessInfo.processInfo.environment["LRCDF_DEBUG"] != nil { print(String(format: "  face %d make-up score %.2f -> %.2f", i, sc, out[i].makeup)) }
            }
        }
        return out
    }

    /// The make-up model's score for one face: the box widened 1.3×, square, stretched to 256 px (sRGB numbers).
    private func makeupScore(_ srgb: CIImage, _ box: CGRect, _ model: MLModel) -> Float {
        let e = srgb.extent, n = 256
        let b = CGRect(x: box.minX * e.width, y: box.minY * e.height, width: box.width * e.width, height: box.height * e.height)
        let side = max(b.width, b.height) * 1.3
        let r = CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
        let s = CGFloat(n) / side
        var small = srgb.clampedToExtent().cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        small = s < 1 ? small.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                      : small.transformed(by: CGAffineTransform(scaleX: s, y: s))
        var px = [Float](repeating: 0, count: n * n * 4)
        context.render(small, toBitmap: &px, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32) else { return -10 }
        let ip = input.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(n * n) { for c in 0..<3 { ip[c * n * n + i] = min(max(px[i * 4 + c], 0), 1) } }
        guard let res = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let v = res.featureValue(for: "score")?.multiArrayValue else { return -10 }
        return MLShapedArray<Float>(converting: v).scalars.first ?? -10
    }

    /// RetinaFace (ResNet-50, the Mac pipeline's detector) on a 960 px copy: boxes and five points, normalised.
    private func retina(_ srgb: CIImage) -> [(box: CGRect, points: [CGPoint], score: Float)] {
        guard let detector = Self.load("RetinaFace", config) else { return [] }
        let S = 960, e = srgb.extent
        let s = CGFloat(S) / max(e.width, e.height)
        let h = e.height * s
        // shrunk, its top edge at the top of the square (rows of the bitmap = y downwards from the top)
        let small = srgb.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(S) - h))
        var px = [Float](repeating: 0, count: S * S * 4)
        context.render(small, toBitmap: &px, rowBytes: S * 16, bounds: CGRect(x: 0, y: 0, width: S, height: S), format: .RGBAf, colorSpace: nil)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)], dataType: .float32) else { return [] }
        let ip = input.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(S * S) { for c in 0..<3 { ip[c * S * S + i] = min(max(px[i * 4 + c], 0), 1) } }
        guard let r = try? detector.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let b = r.featureValue(for: "boxes")?.multiArrayValue, let sc = r.featureValue(for: "scores")?.multiArrayValue,
              let lm = r.featureValue(for: "landmarks")?.multiArrayValue else { return [] }
        let boxes = MLShapedArray<Float>(converting: b).scalars, scores = MLShapedArray<Float>(converting: sc).scalars
        let marks = MLShapedArray<Float>(converting: lm).scalars
        // model units (0..1 of the square, y down) -> picture, normalised, y up
        let k = Float(S) / Float(s)
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x * k) / e.width, y: 1 - CGFloat(y * k) / e.height) }
        var cand = scores.indices.filter { scores[$0] > 0.7 }.sorted { scores[$0] > scores[$1] }
        var kept: [(box: CGRect, points: [CGPoint], score: Float)] = []
        var keptRaw: [CGRect] = []
        while let i = cand.first {
            cand.removeFirst()
            let r = CGRect(x: CGFloat(boxes[i * 4]), y: CGFloat(boxes[i * 4 + 1]), width: CGFloat(boxes[i * 4 + 2] - boxes[i * 4]), height: CGFloat(boxes[i * 4 + 3] - boxes[i * 4 + 1]))
            if keptRaw.contains(where: { iou($0, r) > 0.4 }) { continue }
            keptRaw.append(r)
            let a = pt(boxes[i * 4], boxes[i * 4 + 3]), c = pt(boxes[i * 4 + 2], boxes[i * 4 + 1])      // bottom-left, top-right
            var p = (0..<5).map { pt(marks[i * 10 + 2 * $0], marks[i * 10 + 2 * $0 + 1]) }
            if p[0].x > p[1].x { p.swapAt(0, 1) }
            if p[3].x > p[4].x { p.swapAt(3, 4) }
            let box = CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !box.isEmpty { kept.append((box, p, scores[i])) }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b); if i.isNull { return 0 }
        let x = i.width * i.height; return x / (a.width * a.height + b.width * b.height - x)
    }

    /// Face + body skin confidence over `rect` (256×256, stretched like MediaPipe's segmenter does).
    private func skinMap(_ srgb: CIImage, _ rect: CGRect) -> CIImage? {
        guard let v = segment(srgb, rect) else { return nil }
        return grey(v, 256, 256)
    }
    /// The same as numbers: 256×256, top row first.
    private func segment(_ srgb: CIImage, _ rect: CGRect) -> [Float]? {
        guard let seg else { return nil }
        let n = 256
        let small = srgb.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(n) / rect.width, y: CGFloat(n) / rect.height)))
        var px = [Float](repeating: 0, count: n * n * 4)
        context.render(small, toBitmap: &px, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: n), 3], dataType: .float32) else { return nil }
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(n * n) { for c in 0..<3 { p[i * 3 + c] = min(max(px[i * 4 + c], 0), 1) } }
        guard let r = try? seg.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let conf = r.featureValue(for: "conf")?.multiArrayValue else { return nil }
        let c = MLShapedArray<Float>(converting: conf).scalars       // [1][y][x][6]
        return (0..<(n * n)).map { min(max(c[$0 * 6 + 2] + c[$0 * 6 + 3], 0), 1) }
    }
    /// A grey image from numbers (top row first), at the origin.
    fileprivate func grey(_ v: [Float], _ w: Int, _ h: Int) -> CIImage {
        var m = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) { m[i * 4] = v[i]; m[i * 4 + 1] = v[i]; m[i * 4 + 2] = v[i] }
        return CIImage(bitmapData: m.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16,
                       size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
    }

    // MARK: blemish model (RetouchNet, trained on FFHQR)

    /// What the blemish model would change on each face, as images in `image`'s pixels (colour layer only, its
    /// overall colour shift removed, feathered). `image`: the decoded (linear) picture at any size; `fullWidth`: width of the
    /// full-size picture (faces whose crop covers under 300 px of it are left to the rest of the pipeline).
    func edits(_ image: CIImage, faces: [Face], fullWidth: CGFloat) -> [CIImage?] {
        guard let retouch = Self.load("RetouchNet", config) else { return faces.map { _ in nil } }
        return faces.map { f in autoreleasepool { edit(image, f, fullWidth: fullWidth, retouch) } }
    }

    private func edit(_ image: CIImage, _ f: Face, fullWidth: CGFloat, _ retouch: MLModel) -> CIImage? {
        let W = image.extent.width, H = image.extent.height
        guard let (T, side) = align(f, W, H, 1024), side * Double(fullWidth / W) >= 300 else { return nil }
        let n = 1024
        let crop = warp(image, T, n)
        var px = [Float](repeating: 0, count: n * n * 4)
        Engine.shared.context.render(crop, toBitmap: &px, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: Engine.shared.srgb)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32) else { return nil }
        let ip = input.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<(n * n) { for ch in 0..<3 { ip[ch * n * n + i] = min(max(px[i * 4 + ch], 0), 1) } }
        guard let r = try? retouch.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let out = r.featureValue(for: "delta")?.multiArrayValue else { return nil }
        var d = MLShapedArray<Float>(converting: out).scalars      // [1][3][y][x], 0..1 units
        // feather (legacy.feather at 1024) and the median shift inside it
        var feather = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let rr = (pow((Float(x) - 511) / 352, 2) + pow((Float(y) - 544) / 448, 2)).squareRoot()
            feather[y * n + x] = min(max((1 - rr) / 0.25, 0), 1)
        } }
        let inside = feather.indices.filter { feather[$0] > 0.5 }
        var blurred = [Float](repeating: 0, count: n * n)
        let sigma = 512 * Float(Self.SPLIT)
        let kernel = gaussianKernel(sigma)
        var rgba = [Float](repeating: 1, count: n * n * 4)
        for ch in 0..<3 {
            let med = median(inside.map { d[ch * n * n + $0] })
            d.withUnsafeMutableBufferPointer { buf in
                for i in 0..<(n * n) { buf[ch * n * n + i] -= med }
                var srcB = vImage_Buffer(data: buf.baseAddress! + ch * n * n, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
                blurred.withUnsafeMutableBufferPointer { bb in
                    var dst = vImage_Buffer(data: bb.baseAddress!, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
                    _ = kernel.withUnsafeBufferPointer { k in
                        vImageSepConvolve_PlanarF(&srcB, &dst, nil, 0, 0, k.baseAddress!, UInt32(k.count), k.baseAddress!, UInt32(k.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
            for i in 0..<(n * n) { rgba[i * 4 + ch] = blurred[i] * feather[i] }
        }
        let img = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: n * 16,
                          size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
        return img.transformed(by: T.inverted()).cropped(to: image.extent)
    }

    /// legacy.face_transform: picture (Core Image pixels, W×H) -> FFHQ-aligned N×N crop, y up in both.
    /// side: how many pixels of this picture the crop covers.
    private func align(_ f: Face, _ W: CGFloat, _ H: CGFloat, _ N: Double) -> (CGAffineTransform, Double)? {
        func top(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x * W), Double((1 - p.y) * H)) }     // top-left pixels
        guard f.points.count == 5 else { return nil }
        let e0 = top(f.points[0]), e1 = top(f.points[1]), m0 = top(f.points[3]), m1 = top(f.points[4])
        let eyes = (e0 + e1) / 2, mouth = (m0 + m1) / 2
        var h = e1 - e0
        let scale = max(simd_length(h) * 2, simd_length(mouth - eyes) * 1.8)
        guard scale > 1 else { return nil }
        h = h / simd_length(h) * scale
        let v = SIMD2(-h.y, h.x)
        let c = eyes + 0.1 * (mouth - eyes)
        let P0 = c - h - v
        let a = (N - 1) * h / (2 * scale * scale), b = (N - 1) * v / (2 * scale * scale)   // crop u = a·(p-P0), v = b·(p-P0)
        let T = CGAffineTransform(a: a.x, b: -b.x, c: -a.y, d: b.y,
                                  tx: a.y * Double(H) - simd_dot(a, P0), ty: N - b.y * Double(H) + simd_dot(b, P0))
        return (T, 2 * scale)
    }
    /// The aligned crop (cv2.warpAffine with INTER_AREA when shrinking: a proper downscale first, then the small rotation).
    private func warp(_ image: CIImage, _ T: CGAffineTransform, _ n: Int) -> CIImage {
        let s0 = hypot(T.a, T.b)
        var src = image.clampedToExtent(), Tt = T
        if s0 < 0.7 {
            src = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s0, kCIInputAspectRatioKey: 1]).clampedToExtent()
            Tt = CGAffineTransform(scaleX: 1 / s0, y: 1 / s0).concatenating(T)
        }
        return src.transformed(by: Tt).cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    }

    private func gaussianKernel(_ s: Float) -> [Float] {
        let r = Int(ceil(3 * s)); var k = (-r...r).map { expf(-Float($0 * $0) / (2 * s * s)) }
        let t = k.reduce(0, +); k = k.map { $0 / t }; return k
    }

    private func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        var h = [Int](repeating: 0, count: 4096)
        for x in v { h[min(max(Int((x + 0.5) * 4096), 0), 4095)] += 1 }
        var acc = 0
        for (i, c) in h.enumerated() { acc += c; if acc * 2 >= v.count { return (Float(i) + 0.5) / 4096 - 0.5 } }
        return 0
    }

    // MARK: retouching

    /// `enc`: the finished picture with sRGB-encoded numbers (after tone). Returns the same, retouched.
    /// `memo`: measurements kept for this photo and look (body skin plan, noise, the guard's verdicts), so a second
    /// render only builds the graph. `fullWidth`: width of the full-size picture (0: this one).
    func apply(_ enc: CIImage, faces: [Face], edits: [CIImage?], level: BeautyLevel, memo: BeautyMemo? = nil, fullWidth: CGFloat = 0) -> CIImage {
        guard let st = level.strength, !faces.isEmpty else { return enc }
        let memo = memo ?? BeautyMemo()
        let e = enc.extent, W = e.width, H = e.height
        var out = enc
        // 1. the blemish model, gated by skin (beautify.retouch → legacy.blend_float)
        let amount = st.skip.contains("model") ? 0 : min(1, st.blemish)
        for (i, f) in faces.enumerated() {
            guard i < edits.count, let ed = edits[i], let skin = skinImage(f, W, H) else { continue }
            out = K.addMasked.apply(extent: e, arguments: [out, ed.cropped(to: e), skin, amount])!
        }
        // 2. each face in its own crop (beauty.beautify)
        let rects = faces.map { f -> CGRect in
            let px = CGRect(x: f.box.minX * W, y: f.box.minY * H, width: f.box.width * W, height: f.box.height * H)
            let m = 0.6 * max(px.width, px.height)
            return px.insetBy(dx: -m, dy: -m).intersection(e).integral
        }
        for (i, f) in faces.enumerated() {
            let R = rects[i]
            guard R.width > 8, R.height > 8 else { continue }
            debugFace = i
            if Beauty.debugDir != nil { print("  face \(i) crop", Int(R.minX), Int(e.height - R.maxY), Int(R.width), Int(R.height), "mesh", f.mesh) }
            let done = face(out.cropped(to: R), f, R, W, H, st, memo: memo, key: "\(level.rawValue).\(i)")
            // fade in at the crop's sides, not where the picture ends; other faces inside the crop are theirs
            let fw = f.width * W, r = max(2, 0.15 * fw)
            var fade = K.fade.apply(extent: R, arguments: [CIVector(cgRect: R), r,
                CIVector(x: R.minX > e.minX ? 1 : 0, y: R.maxX < e.maxX ? 1 : 0, z: R.minY > e.minY ? 1 : 0, w: R.maxY < e.maxY ? 1 : 0)])!
            let canvas = Canvas(R, scale: min(1, 300 / fw))
            let others = faces.enumerated().filter { $0.offset != i && rects[$0.offset].intersects(R) }.map { $0.element }
            if !others.isEmpty {
                let m = canvas.mask(blur: 0.06 * fw) { ctx, p in
                    for o in others {
                        let b = CGRect(x: o.box.minX * W, y: o.box.minY * H, width: o.box.width * W, height: o.box.height * H)
                        let c = p(CGPoint(x: b.midX, y: b.midY + 0.05 * b.height)), sc = canvas.scale
                        ctx.fillEllipse(in: CGRect(x: c.x - 0.62 * b.width * sc, y: c.y - 0.75 * b.height * sc, width: 1.24 * b.width * sc, height: 1.5 * b.height * sc))
                    }
                }
                fade = K.mul.apply(extent: R, arguments: [fade, K.invert.apply(extent: R, arguments: [m])!])!
            }
            out = K.mix.apply(extent: e, arguments: [out, done, fade.cropped(to: R)])!
        }
        // 3. skin below and beside the faces
        let t0 = Date()
        let env = ProcessInfo.processInfo.environment
        if env["LRCDF_NOBODY"] == nil { out = body(out, raw: enc, faces: faces, st: st, memo: memo) }
        let t1 = Date()
        // 4. faces retouched more than professionals would are taken back (beautify.guard)
        if env["LRCDF_NOGUARD"] == nil { out = guardFaces(enc, out, faces: faces, level: level, memo: memo, scale: fullWidth > 0 ? fullWidth / W : 1) }
        if ProcessInfo.processInfo.environment["LRCDF_DEBUG"] != nil { print(String(format: "  build: body %.2fs guard %.2fs", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1))) }
        return out
    }

    /// The face's skin map in the picture's pixels (0 outside its area).
    private func skinImage(_ f: Face, _ W: CGFloat, _ H: CGFloat) -> CIImage? {
        guard let s = f.skin else { return nil }
        let a = CGRect(x: f.area.minX * W, y: f.area.minY * H, width: f.area.width * W, height: f.area.height * H)
        return s.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: a.width / 256, y: a.height / 256).concatenating(CGAffineTransform(translationX: a.minX, y: a.minY)))
            .cropped(to: a)
    }

    /// beauty.beautify_face on one crop.
    private func face(_ crop: CIImage, _ face: Face, _ R: CGRect, _ W: CGFloat, _ H: CGFloat, _ st: Strength, memo: BeautyMemo, key: String) -> CIImage {
        let f = face.width * W
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        let eyeL = face.eyeL.map(px), eyeR = face.eyeR.map(px), browL = face.browL.map(px), browR = face.browR.map(px)
        let lipsOut = face.lipsOut.map(px), lipsIn = face.lipsIn.map(px)
        let canvas = Canvas(R, scale: min(1, 400 / f))

        // features (eyes, brows, lips): left alone by the skin steps
        let five = face.points.map(px)
        var features = canvas.mask(grow: f * 0.02, blur: f * 0.012) { ctx, p in
            for poly in [eyeL, eyeR, browL, browR, lipsOut] where poly.count > 2 { fill(ctx, poly.map(p)) }
        }
        if !face.mesh, five.count == 5 {      // no mesh: generous ovals over each eye with its brow, and over the mouth
            let sc = canvas.scale
            features = K.lin.apply(extent: R, arguments: [canvas.mask(blur: f * 0.02) { ctx, p in
                for e in five[0...1] {
                    let c = p(CGPoint(x: e.x, y: e.y + f * 0.04))
                    ctx.fillEllipse(in: CGRect(x: c.x - f * 0.17 * sc, y: c.y - f * 0.15 * sc, width: f * 0.34 * sc, height: f * 0.30 * sc))
                }
                let m0 = five[3], m1 = five[4]
                let c = p(CGPoint(x: (m0.x + m1.x) / 2, y: (m0.y + m1.y) / 2))
                let ax = max(hypot(m1.x - m0.x, m1.y - m0.y) * 0.7, f * 0.14)
                ctx.fillEllipse(in: CGRect(x: c.x - ax * sc, y: c.y - f * 0.12 * sc, width: 2 * ax * sc, height: f * 0.24 * sc))
            }, 1.5, 0])!
        }
        guard let rawSkin = skinImage(face, W, H) else { return crop }
        dump("rawskin", rawSkin.cropped(to: R)); dump("features", features)
        let skin = K.skinPrep.apply(extent: R, arguments: [blur(K.lin.apply(extent: R, arguments: [rawSkin.cropped(to: R), 1.5, -0.25])!, f * 0.012), features])!
        let (low0, high0) = (blur(crop, f * Self.SPLIT), crop)        // high = crop - low (formed below)

        // low layer: edge-aware smoothing on a copy where the face is at most 320 px wide
        let d = min(1, 320 / f)
        let small = scaled(low0, d)
        let ss = f * d * 0.045
        var b = small
        for _ in 0..<2 { b = K.bilateral(b, radius: (1.5 * ss).rounded(), ss: ss, sc: 0.07) }
        let base = up(b, R)
        var low = K.mixAmt.apply(extent: R, arguments: [low0, base, skin, st.skip.contains("smooth") ? 0 : st.smooth])!
        var heal = K.zero.apply(extent: R, arguments: [])!
        let onSkin = K.lin.apply(extent: R, arguments: [skin, 1.5, 0])!

        // red marks, relief and shine, in Lab on the small copy
        if st.spots > 0 || st.shine > 0 {
            let sm = scaled(low, d)
            let se = sm.extent
            let wt = scaled(skin, d)
            let lab = K.rgb2lab.apply(extent: se, arguments: [sm])!
            let sigma = f * d * 0.06
            var keep = wt
            var around = lab
            for _ in 0..<4 {
                let norm = blur(keep, sigma)
                around = K.divide.apply(extent: se, arguments: [blur(K.mul.apply(extent: se, arguments: [lab, keep])!, sigma), norm])!
                keep = K.keep.apply(extent: se, arguments: [lab, around, wt])!
            }
            var spot = K.spot.apply(extent: se, arguments: [lab, around, wt])!
            let k = max(3, Int(f * d * Self.SPOT_WIDTH * CGFloat(pow(max(1, st.spots), 2)))) | 1
            let rad = CGFloat(k - 1) / 2
            let wide = open(spot, rad)
            let bl = f * d * 0.02
            let my = blur(K.yellow.apply(extent: se, arguments: [lab, around])!, bl)       // (b-b_around, max(red,0), around.L - L)
            // stay on the face; leave the mouth alone
            let small2 = Canvas(R, scale: d)
            // The nose is redder than the cheeks by nature: there only marks narrower than 2 % of the face count (pimples), its own colour is not a blemish
            // (the whole tip was taken as one wide red mark and went pale: man4, Mac and iPad alike).
            let noseZone = small2.mask(grow: f * 0.03, blur: f * 0.03, small: true) { ctx, p in
                if face.nose.count > 2 { fill(ctx, hull(face.nose.map(px)).map(p)) }
                else if five.count == 5 { let c = p(five[2]), r = f * 0.12 * d; ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
            }
            dump("nosezone", noseZone)
            let pimple = open(spot, max(1, (f * d * 0.02 - 1) / 2))      // on the nose a mark is only what is narrower than 2 % of the face
            spot = K.inflame.apply(extent: se, arguments: [spot, wide, my, pimple, st.skip.contains("nose") ? K.zero.apply(extent: se, arguments: [])! : noseZone.cropped(to: se)])!
            let bx = CGRect(x: face.box.minX * W, y: face.box.minY * H, width: face.box.width * W, height: face.box.height * H)
            let onFace = small2.mask(blur: f * d * 0.05, small: true) { ctx, p in
                let c = p(CGPoint(x: bx.midX, y: bx.midY))
                ctx.fillEllipse(in: CGRect(x: c.x - bx.width * 0.62 * d, y: c.y - bx.height * 0.7 * d, width: bx.width * 1.24 * d, height: bx.height * 1.4 * d))
            }
            var notMouth: CIImage? = nil
            if five.count == 5 {
                let m0 = five[3], m1 = five[4]
                let half = max(hypot(m1.x - m0.x, m1.y - m0.y) * 0.65, f * 0.12)
                let ang = half > f * 0.12 ? atan2(m1.y - m0.y, m1.x - m0.x) : 0
                notMouth = K.invert.apply(extent: se, arguments: [small2.mask(blur: f * d * 0.02, small: true) { ctx, p in
                    let c = p(CGPoint(x: (m0.x + m1.x) / 2, y: (m0.y + m1.y) / 2))
                    ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: ang)
                    ctx.fillEllipse(in: CGRect(x: -half * d, y: -f * 0.11 * d, width: 2 * half * d, height: 0.22 * f * d)); ctx.restoreGState()
                }])!
            }
            spot = K.mul.apply(extent: se, arguments: [spot, onFace.cropped(to: se)])!
            if let nm = notMouth { spot = K.mul.apply(extent: se, arguments: [spot, nm.cropped(to: se)])! }
            // make-up safe: red laid in a band (blush under the eye, eye shadow, a lip line) is make-up, not a blemish;
            // blemishes are round. Each patch of the mark map is measured; long thin ones are left alone.
            let mk = st.skip.contains("makeup") ? 0 : CGFloat(face.makeup)
            // Below the eyes the same holds for everyone: the crease under an eye bag is a long dark-red arc, and
            // corrected as a mark it turned the bag into a pale disc (oldman3, Mac and iPad alike).
            var underZone: CIImage? = nil
            if eyeL.count > 2, eyeR.count > 2, lipsOut.count > 2 {
                let mid = { (ps: [CGPoint]) -> CGPoint in CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count)) }
                let em = CGPoint(x: (mid(eyeL).x + mid(eyeR).x) / 2, y: (mid(eyeL).y + mid(eyeR).y) / 2), lm = mid(lipsOut)
                var down = CGPoint(x: lm.x - em.x, y: lm.y - em.y)
                let dl = hypot(down.x, down.y) + 1e-6; down = CGPoint(x: down.x / dl, y: down.y / dl)
                let ang = atan2(down.y, down.x) + .pi / 2
                var ews: [CGFloat] = []
                for eye in [eyeL, eyeR] { var ew: CGFloat = 0; for p in eye { for q in eye { ew = max(ew, hypot(p.x - q.x, p.y - q.y)) } }; ews.append(ew) }
                underZone = small2.mask(blur: max(ews[0], ews[1]) * 0.2, small: true) { ctx, p in
                    for (eye, ew) in zip([eyeL, eyeR], ews) where ew > 4 {
                        let c = mid(eye), q = p(CGPoint(x: c.x + down.x * ew * 0.75, y: c.y + down.y * ew * 0.75))
                        ctx.saveGState(); ctx.translateBy(x: q.x, y: q.y); ctx.rotate(by: ang)
                        ctx.fillEllipse(in: CGRect(x: -ew * 0.95 * d, y: -ew * 0.6 * d, width: 1.9 * ew * d, height: 1.2 * ew * d)); ctx.restoreGState()
                    }
                }.cropped(to: se)
            }
            if (mk > 0 || underZone != nil), !st.skip.contains("shape") {
                let spotNow = spot
                let keepMap: [Float]? = memo.value("bands.\(key)") { self.roundOnly(spotNow, f * d) }
                if let km = keepMap {
                    let k = grey(km, Int(se.width.rounded(.up)), Int(se.height.rounded(.up))).transformed(by: CGAffineTransform(translationX: se.minX, y: se.minY))
                    let soft = blur(k.cropped(to: se), max(0.6, f * d * 0.004))
                    dump("keepround", soft)
                    let zone = underZone ?? K.zero.apply(extent: se, arguments: [])!
                    if let u = underZone { dump("underzone", u) }
                    spot = K.bandOff.apply(extent: se, arguments: [spot, soft, zone, mk])!
                }
            }
            spot = blur(spot, max(0.6, f * d * 0.004))
            // relief: small light/dark patches right around the marks
            let near = K.lin.apply(extent: se, arguments: [blur(spot, f * d * 0.02), CGFloat(Self.RELIEF_REACH), 0])!
            var bump = K.bump.apply(extent: se, arguments: [lab, around, near, wt])!
            bump = K.sub.apply(extent: se, arguments: [bump, open(bump, rad)])!
            bump = K.subPos.apply(extent: se, arguments: [blur(bump, max(0.6, f * d * 0.004)), spot])!
            if let u = underZone, !st.skip.contains("shape") {     // no relief below the eyes: there light and shade are the eye bag's own shape
                bump = K.mul.apply(extent: se, arguments: [bump, K.invert.apply(extent: se, arguments: [u])!])!
            }
            var glare = K.zero.apply(extent: se, arguments: [])!
            if st.shine > 0 { glare = blur(K.glare.apply(extent: se, arguments: [lab, around, wt])!, max(0.8, f * d * 0.008)) }
            _ = around
            let fixed = K.fix.apply(extent: se, arguments: [lab, around, spot, bump, glare, min(1, st.spots), Self.RELIEF * min(1, st.spots), min(1, st.shine) * 0.7])!
            let delta = K.sub.apply(extent: se, arguments: [K.lab2rgb.apply(extent: se, arguments: [fixed])!, sm])!
            dump("spot", spot); dump("bump", bump); dump("glare", glare); dump("delta", delta, gain: 5, offset: 0.5); dump("around", around, gain: 0.01)
            low = K.addMasked.apply(extent: R, arguments: [low, up(delta, R), onSkin, Float(1)])!
            heal = K.marks.apply(extent: R, arguments: [up(spot, R), up(bump, R), onSkin, Self.RELIEF])!
        }
        // high layer: kept, except toned down on blemishes and on shine glints
        var high = K.high.apply(extent: R, arguments: [high0, low0, heal, Self.HEAL * min(1, st.spots)])!
        if st.shine > 0 {
            high = K.glint.apply(extent: R, arguments: [high, crop, onSkin, min(1, st.shine) * 0.75])!
        }

        if !face.mesh { return K.clamp.apply(extent: R, arguments: [K.add.apply(extent: R, arguments: [low, high])!])! }
        // under-eyes: the colour layer pulled towards the cheek below
        if eyeL.count > 2, eyeR.count > 2, lipsOut.count > 2 {
            let mid = { (ps: [CGPoint]) -> CGPoint in CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count)) }
            let em = CGPoint(x: (mid(eyeL).x + mid(eyeR).x) / 2, y: (mid(eyeL).y + mid(eyeR).y) / 2), lm = mid(lipsOut)
            var down = CGPoint(x: lm.x - em.x, y: lm.y - em.y)
            let dl = hypot(down.x, down.y) + 1e-6; down = CGPoint(x: down.x / dl, y: down.y / dl)
            let ang = atan2(down.y, down.x) + .pi / 2
            for eye in [eyeL, eyeR] {
                let c = mid(eye)
                var ew: CGFloat = 0
                for p in eye { for q in eye { ew = max(ew, hypot(p.x - q.x, p.y - q.y)) } }
                guard ew > 4 else { continue }
                let ue = Canvas(R, scale: canvas.scale)
                func ell(_ cc: CGPoint, _ ax: CGFloat, _ ay: CGFloat, _ bl: CGFloat) -> CIImage {
                    ue.mask(blur: bl) { ctx, p in
                        let q = p(cc), s = ue.scale
                        ctx.saveGState(); ctx.translateBy(x: q.x, y: q.y); ctx.rotate(by: ang)
                        ctx.fillEllipse(in: CGRect(x: -ax * s, y: -ay * s, width: 2 * ax * s, height: 2 * ay * s)); ctx.restoreGState()
                    }
                }
                let u0 = ell(CGPoint(x: c.x + down.x * ew * 0.62, y: c.y + down.y * ew * 0.62), ew * 0.72, ew * 0.36, ew * 0.25)   // a soft edge (0.12 left a visible oval: oldman3)
                let eyeMask = ue.mask(grow: ew * 0.12, blur: ew * 0.06) { ctx, p in fill(ctx, eye.map(p)) }
                let under = K.underMask.apply(extent: R, arguments: [u0, eyeMask, skin])!
                let cheek = K.mul.apply(extent: R, arguments: [ell(CGPoint(x: c.x + down.x * ew * 1.45, y: c.y + down.y * ew * 1.45), ew * 0.6, ew * 0.35, ew * 0.1), skin])!
                let avg = { (img: CIImage) -> CIImage in img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: R)]).clampedToExtent() }
                let area = Float(R.width * R.height)
                // the under-eye's own level, locally (a masked blur): only what is darker than the cheek is lifted, by
                // as much as it is darker - a uniform shift lifted the bright part of an eye bag too and made a flat disc
                let sg = ew * 0.15
                let local = K.divide.apply(extent: R, arguments: [blur(K.mul.apply(extent: R, arguments: [base, under])!, sg), blur(under, sg)])!
                low = K.underEye.apply(extent: R, arguments: [low, under,
                    avg(K.mul.apply(extent: R, arguments: [base, cheek])!), avg(cheek),
                    avg(K.mul.apply(extent: R, arguments: [base, under])!), avg(under), local, (st.skip.contains("undereye") ? 0 : st.undereye), area, st.skip.contains("makeup") ? 0 : face.makeup])!
            }
        }
        dump("skin", skin); dump("lowchange", K.sub.apply(extent: R, arguments: [low, low0])!, gain: 5, offset: 0.5)
        var out = K.add.apply(extent: R, arguments: [low, high])!

        // wrinkles: fine dark lines are filled part of the way (more with stronger smoothing); texture stays
        let wAmount = Self.WRINKLES * min(1.5, CGFloat(st.smooth) / 0.6)
        if wAmount > 0, f >= 200, !st.skip.contains("wrinkles") {
            let lids = canvas.mask(blur: f * 0.015) { ctx, p in        // the lid crease belongs to the eye
                for poly in [eyeL + browL, eyeR + browR] where poly.count > 2 { fill(ctx, hull(poly).map(p)) }
            }
            var keepM = K.maxOf.apply(extent: R, arguments: [features, lids])!
            if face.nose.count > 2 {
                let nostrils = canvas.mask(grow: f * 0.02, blur: f * 0.012) { ctx, p in fill(ctx, face.nose.map(px).map(p)) }
                keepM = K.maxOf.apply(extent: R, arguments: [keepM, nostrils])!
            }
            let whereW = K.lineWhere.apply(extent: R, arguments: [skin, keepM])!
            let gain = softenLines(out, whereW, f, min(1, wAmount), R)
            out = K.mul3.apply(extent: R, arguments: [out, gain])!
        }

        // eyes: a little clarity and brightness inside the eye opening
        if st.eyes > 0, eyeL.count > 2, eyeR.count > 2 {
            let eyes = canvas.mask(blur: f * 0.006) { ctx, p in fill(ctx, eyeL.map(p)); fill(ctx, eyeR.map(p)) }
            out = K.eyes.apply(extent: R, arguments: [out, crop, blur(crop, f * 0.02), eyes, st.eyes])!
        }
        // teeth: bright, low-saturation pixels inside the lips
        if st.teeth > 0, lipsIn.count > 2 {
            let mouth = canvas.mask(blur: f * 0.004) { ctx, p in fill(ctx, lipsIn.map(p)) }
            out = K.teeth.apply(extent: R, arguments: [out, crop, mouth, st.teeth])!
        }
        return K.clamp.apply(extent: R, arguments: [out])!
    }

    /// Made-up faces, and below the eyes on every face: acne clusters on bare cheeks can be long patches too.
    /// 1 on round marks, 0 on patches laid in a band (area over ~3 × thickness², bigger than 3–5 % of the face):
    /// make-up (blush under the eyes, eye shadow, lip line) rather than blemishes. `fs`: face width on this copy.
    /// Top row first, at the map's own size.
    private func roundOnly(_ spot: CIImage, _ fs: CGFloat) -> [Float]? {
        let e = spot.extent, w = Int(e.width.rounded(.up)), h = Int(e.height.rounded(.up))
        guard w > 2, h > 2 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(spot, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBAf, colorSpace: nil)
        // distance to the nearest unmarked pixel (two-pass chamfer 1 / 1.41)
        var dist = (0..<(w * h)).map { px[$0 * 4] > 0.25 ? Float.greatestFiniteMagnitude : 0 }
        for y in 0..<h { for x in 0..<w where dist[y * w + x] > 0 {
            var v = dist[y * w + x]
            v = min(v, x > 0 ? dist[y * w + x - 1] + 1 : 1, y > 0 ? dist[(y - 1) * w + x] + 1 : 1)
            v = min(v, x > 0 && y > 0 ? dist[(y - 1) * w + x - 1] + 1.414 : 1.414, x < w - 1 && y > 0 ? dist[(y - 1) * w + x + 1] + 1.414 : 1.414)
            dist[y * w + x] = v
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where dist[y * w + x] > 0 {
            var v = dist[y * w + x]
            v = min(v, x < w - 1 ? dist[y * w + x + 1] + 1 : 1, y < h - 1 ? dist[(y + 1) * w + x] + 1 : 1)
            v = min(v, x < w - 1 && y < h - 1 ? dist[(y + 1) * w + x + 1] + 1.414 : 1.414, x > 0 && y < h - 1 ? dist[(y + 1) * w + x - 1] + 1.414 : 1.414)
            dist[y * w + x] = v
        } }
        var label = [Int32](repeating: -1, count: w * h)
        var keep = [Float](repeating: 1, count: w * h)
        var stack: [Int] = []
        var removed = 0
        for start in 0..<(w * h) where label[start] < 0 && px[start * 4] > 0.25 {
            label[start] = Int32(start); stack = [start]
            var members: [Int] = []
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if label[j] < 0 && px[j * 4] > 0.25 { label[j] = Int32(start); stack.append(j) }
                }
            }
            let n = Double(members.count)
            guard n >= 6 else { continue }
            // thickness = twice the deepest point inside the patch; a round mark has area ≈ 0.8 thickness²,
            // a band (straight or curved) about length / width times that
            var deepest: Float = 0
            for i in members { deepest = max(deepest, dist[i]) }
            let thick = Double(2 * deepest), ratio = n / max(thick * thick, 1)
            var mx = 0.0, my = 0.0
            for i in members { mx += Double(i % w); my += Double(i / w) }
            mx /= n; my /= n
            var cxx = 0.0, cyy = 0.0, cxy = 0.0
            for i in members { let dx = Double(i % w) - mx, dy = Double(i / w) - my; cxx += dx * dx; cyy += dy * dy; cxy += dx * dy }
            cxx /= n; cyy /= n; cxy /= n
            let tr = (cxx + cyy) / 2, det = (((cxx - cyy) / 2) * ((cxx - cyy) / 2) + cxy * cxy).squareRoot()
            let elong = ((tr + det) / (max(tr - det, 0) + 0.25)).squareRoot()
            let size = min(max((n.squareRoot() - Double(fs) * 0.03) / (Double(fs) * 0.02), 0), 1)
            let band = max(min(max((ratio - 2.5) / 1.5, 0), 1), min(max(elong - 2.0, 0), 1)) * size
            if Beauty.debugDir != nil, n > 30 { print(String(format: "    patch at %.0f,%.0f n %.0f thick %.1f ratio %.2f elong %.2f size %.2f -> band %.2f", mx, my, n, thick, ratio, elong, size, band)) }
            if band > 0 { removed += 1; for i in members { keep[i] = Float(1 - band) } }
        }
        // the faint edge of a removed patch goes with it
        let grown = dilate(keep.map { 1 - $0 }, w, h, 5)
        if Beauty.debugDir != nil { print("  make-up bands left alone: \(removed)") }
        return grown.map { 1 - $0 }
    }

    /// beauty.soften_lines: gain (≥ 1) over R that fills thin dark lines in skin. A line is a narrow valley in
    /// brightness, long rather than round (pores, moles) and shallow (hair, lashes, frames are deep and stay).
    private func softenLines(_ img: CIImage, _ wh: CIImage, _ f: CGFloat, _ amount: CGFloat, _ R: CGRect) -> CIImage {
        let g = min(1, Self.LINE_SCALE / f), n = f * g
        let lum = K.luma.apply(extent: img.extent, arguments: [img])!
        let small = scaled(lum, g), se = small.extent
        let fine = blur(small, n * 0.004)
        let k = max(3, Int(n * Self.LINE_WIDTH)) | 1, r = CGFloat(k - 1) / 2
        let filled = morph(morph(fine, r, max: true), r, max: false)            // closing
        let depth = K.depth.apply(extent: se, arguments: [filled, fine])!
        let b = blur(small, n * 0.006)
        let long = blur(K.hessian(b), n * 0.006)
        let deepest = morph(depth, r, max: true)
        var line = K.line.apply(extent: se, arguments: [depth, long, deepest, CIVector(x: CGFloat(Self.LINES.0), y: CGFloat(Self.LINES.1), z: CGFloat(Self.LINES.2), w: CGFloat(Self.LINES.3))])!
        line = K.mul.apply(extent: se, arguments: [blur(line, max(0.6, n * 0.004)), scaled(wh, g).cropped(to: se)])!
        dump("lines", line, gain: 3)
        return up(K.lineGain.apply(extent: se, arguments: [line, filled, fine, amount])!, R)
    }

    /// beauty.beautify_body: the skin outside the face crops (neck, arms, hands, chest, legs) gets the same
    /// low-layer evening at 0.75 of the face's amount, switched off on body hair; with one face, the body's skin
    /// colour is nudged towards the face's. `enc`: whole picture (sRGB numbers), after the faces.
    private struct BodyPlan {
        var skin: [Float], whole: [Float]
        var shift: SIMD2<Float>?        // Lab a, b added to body skin (one face only)
        var region: CGRect?             // where body skin is, normalised
    }
    /// `raw`: the picture before retouching (segmented and read for noise: the faces' graphs need not be evaluated).
    private func body(_ enc: CIImage, raw: CIImage, faces: [Face], st: Strength, memo: BeautyMemo) -> CIImage {
        let e = enc.extent, W = e.width, H = e.height
        guard st.smooth > 0 else { return enc }
        let n = 256
        let widths = faces.map { $0.width * W }.sorted()
        let f = widths[widths.count / 2]
        let boxes = faces.map { CGRect(x: $0.box.minX * W, y: (1 - $0.box.maxY) * H, width: $0.box.width * W, height: $0.box.height * H) }   // top-left pixels
        let plan: BodyPlan? = memo.value("body") { () -> BodyPlan? in
            guard let v = self.segment(raw, e) else { return nil }
            let grown = boxes.map { b in b.insetBy(dx: -0.6 * max(b.width, b.height), dy: -0.6 * max(b.width, b.height)) }
            var whole = [Float](repeating: 0, count: n * n), skin = whole
            var onFace: [Int] = [], onBody: [Int] = []
            let b0 = boxes[0]
            for i in 0..<(n * n) {
                let p = CGPoint(x: (CGFloat(i % n) + 0.5) / CGFloat(n) * W, y: (CGFloat(i / n) + 0.5) / CGFloat(n) * H)
                whole[i] = min(max(v[i] * 2 - 0.6, 0), 1)
                skin[i] = grown.contains { $0.contains(p) } ? 0 : whole[i]
                if whole[i] > 0.5, p.x >= b0.minX + 0.2 * b0.width, p.x < b0.maxX - 0.2 * b0.width, p.y >= b0.minY + 0.4 * b0.height, p.y < b0.minY + 0.75 * b0.height { onFace.append(i) }
                if skin[i] > 0.5 { onBody.append(i) }
            }
            // one skin colour from face to hands: the body's colour (not its lightness) moved towards the face's
            var shift: SIMD2<Float>? = nil
            let sd = min(1, 1536 / max(W, H)), cell = Float(W * sd * H * sd) / Float(n * n)     // the Mac's segmenter copy: pixels per cell
            if Self.UNIFY > 0, faces.count == 1, Float(onFace.count) * cell > 80, Float(onBody.count) * cell > 200 {
                let lab = K.rgb2lab.apply(extent: e, arguments: [enc])!
                    .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: CGFloat(n) / W, y: CGFloat(n) / H)))
                var px = [Float](repeating: 0, count: n * n * 4)
                self.context.render(lab, toBitmap: &px, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
                func med(_ idx: [Int], _ c: Int) -> Float { let s = idx.map { px[$0 * 4 + c] }.sorted(); return s[s.count / 2] }
                let d = SIMD2(med(onFace, 1) - med(onBody, 1), med(onFace, 2) - med(onBody, 2))
                let size = simd_length(d)
                if ProcessInfo.processInfo.environment["LRCDF_DEBUG"] != nil { print("  unify: face-body ab", d, "cells face/body", onFace.count, onBody.count) }
                if size > 1.5, size < 8 { shift = d * min(1, 3 / size) * min(1, Self.UNIFY) }
            }
            var x0 = n, y0 = n, x1 = -1, y1 = -1, count = 0
            for i in 0..<(n * n) where skin[i] > 0.05 { let x = i % n, y = i / n; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); count += 1 }
            let region: CGRect? = x1 >= 0 && Float(count) * cell >= 50
                ? CGRect(x: CGFloat(x0) / CGFloat(n), y: 1 - CGFloat(y1 + 1) / CGFloat(n), width: CGFloat(x1 - x0 + 1) / CGFloat(n), height: CGFloat(y1 - y0 + 1) / CGFloat(n)) : nil
            return BodyPlan(skin: skin, whole: whole, shift: shift, region: region)
        }
        guard let plan else { return enc }
        let stretch = CGAffineTransform(scaleX: W / CGFloat(n), y: H / CGFloat(n)).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY))
        func over(_ a: [Float]) -> CIImage { grey(a, n, n).clampedToExtent().transformed(by: stretch).cropped(to: e) }
        var out = enc
        if let sh = plan.shift {
            let b0 = boxes[0]
            let fb = CGRect(x: b0.minX + e.minX, y: H - b0.maxY + e.minY, width: b0.width, height: b0.height)
            let cv = Canvas(e, scale: min(1, 1024 / max(W, H)))
            let keep = cv.mask(blur: max(1, 0.3 * b0.width)) { ctx, p in let a = p(fb.origin), c = p(CGPoint(x: fb.maxX, y: fb.maxY)); ctx.fill(CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)) }
            let wh = blur(K.notNear.apply(extent: e, arguments: [over(plan.whole), keep])!, f * 0.012)
            let moved = K.lab2rgb.apply(extent: e, arguments: [K.shiftAB.apply(extent: e, arguments: [K.rgb2lab.apply(extent: e, arguments: [out])!, wh, sh.x, sh.y])!])!
            out = K.mix.apply(extent: e, arguments: [enc, moved, K.lin.apply(extent: e, arguments: [wh, 1000, 0])!])!   // untouched where nothing moves
        }
        // evening, in the part of the picture where body skin is
        guard let rn = plan.region else { return out }
        let pad = f * 0.1
        let Rg = CGRect(x: rn.minX * W + e.minX - pad, y: rn.minY * H + e.minY - pad, width: rn.width * W + 2 * pad, height: rn.height * H + 2 * pad).intersection(e).integral
        guard Rg.width > 8, Rg.height > 8 else { return out }
        let part = blur(over(plan.skin).cropped(to: Rg), f * 0.012)
        let region = out.cropped(to: Rg)
        let low = blur(region, f * Self.SPLIT)
        let hair = hairLines(region, f, part, noiseFrom: raw.cropped(to: Rg), memo: memo)
        let d = min(1, 320 / f), ss = f * d * 0.045
        var bsm = scaled(low, d)
        for _ in 0..<2 { bsm = K.bilateral(bsm, radius: (1.5 * ss).rounded(), ss: ss, sc: 0.07) }
        dump("body_part", part); dump("body_hair", hair)
        let done = K.even.apply(extent: Rg, arguments: [region, up(bsm, Rg), low, part, hair, Self.BODY * CGFloat(st.smooth)])!
        return done.composited(over: out)
    }

    /// beauty.hair_lines: where thin dark lines (hair) run, 0…1. A matched filter (the texture layer averaged along
    /// short segments in 12 directions) above what the photo's own noise could give by chance.
    private func hairLines(_ img: CIImage, _ f: CGFloat, _ part: CIImage, noiseFrom raw: CIImage, memo: BeautyMemo) -> CIImage {
        let R = img.extent
        let z = min(1, Self.HAIR_SCALE / f), fz = f * z
        let grey = scaled(K.mean.apply(extent: R, arguments: [img])!, z), se = grey.extent
        let soft = blur(grey, fz * Self.SPLIT)
        let nn = max(7, Int(fz * 0.03)) | 1
        let dark = K.lineResponse(K.sub.apply(extent: se, arguments: [grey, soft])!, CGFloat(nn - 1) / 2)
        // noise level from pixel-to-pixel second differences on skin, read in a few bands of rows
        let floor: Float? = memo.value("hair") { () -> Float? in
            let w = Int(se.width), h = Int(se.height)
            let sk = self.scaled(part, z)
            let rawGrey = self.scaled(K.mean.apply(extent: R, arguments: [raw])!, z)     // the picture before retouching: same noise, cheap to read
            var diffs: [Float] = [], all: [Float] = []
            let bands = 12, rows = 24
            for b in 0..<bands {
                let y = se.minY + CGFloat((h - rows) * b / max(1, bands - 1))
                let rr = CGRect(x: se.minX, y: y, width: CGFloat(w), height: CGFloat(rows)).intersection(se).integral
                guard rr.width > 4, rr.height > 0 else { continue }
                let rw = Int(rr.width), rh = Int(rr.height)
                var g = [Float](repeating: 0, count: rw * rh * 4), m = g
                self.context.render(rawGrey, toBitmap: &g, rowBytes: rw * 16, bounds: rr, format: .RGBAf, colorSpace: nil)
                self.context.render(sk, toBitmap: &m, rowBytes: rw * 16, bounds: rr, format: .RGBAf, colorSpace: nil)
                for yy in 0..<rh { for x in 1..<(rw - 1) {
                    let i = yy * rw + x
                    let s2 = abs(g[(i - 1) * 4] - 2 * g[i * 4] + g[(i + 1) * 4])
                    all.append(s2); if m[i * 4] > 0.5 { diffs.append(s2) }
                } }
            }
            let use = diffs.count > 100 ? diffs : all
            guard !use.isEmpty else { return nil }
            let sorted = use.sorted()
            let sigma = 1.4826 * sorted[sorted.count / 2] / Float(6).squareRoot() + 1e-6
            if Beauty.debugDir != nil { print(String(format: "  hair: noise sigma %.4f, threshold %.4f", sigma, sigma * Self.noiseQ999(fz))) }
            return sigma * Self.noiseQ999(fz)
        }
        guard let floor else { return K.zero.apply(extent: R, arguments: [])! }
        var lines = K.hair.apply(extent: se, arguments: [dark, soft, floor, Self.HAIR.0, Self.HAIR.1 / Self.HAIR.0 - 1])!
        lines = blur(lines, max(0.8, fz * Self.SPLIT))
        return up(K.lin.apply(extent: se, arguments: [lines, 2, 0])!, R)
    }
    /// What pure noise of unit size gives in the line filter (99.9th percentile), by face width on the hair copy
    /// (beauty._noise_response, simulated on the Mac).
    private static func noiseQ999(_ fz: CGFloat) -> Float {
        let t: [(CGFloat, Float)] = [(40, 0), (50, 0.027), (60, 0.14), (80, 0.567), (100, 0.885), (120, 1.049), (140, 1.138), (160, 1.194),
                                     (180, 1.238), (200, 1.270), (233, 1.313), (266, 1.348), (267, 1.207), (300, 1.232), (333, 1.250),
                                     (334, 1.088), (366, 1.101), (400, 1.062)]
        if fz <= t[0].0 { return t[0].1 }
        for i in 1..<t.count where fz <= t[i].0 {
            let (a, va) = t[i - 1], (b, vb) = t[i]; return va + Float((fz - a) / (b - a)) * (vb - va)
        }
        return t.last!.1
    }

    /// beautify.guard: a face retouched more than professionals almost ever do (the critic, trained on FFHQR) is
    /// taken back towards the original, at most half way. Blemish corrections are left out of measuring and taking back.
    /// `scale`: full-size pixels per pixel of this picture (the 200 px limit is in the photo's own pixels).
    private func guardFaces(_ before: CIImage, _ after: CIImage, faces: [Face], level: BeautyLevel, memo: BeautyMemo, scale: CGFloat) -> CIImage {
        guard let st = level.strength else { return after }
        let e = after.extent, W = e.width, H = e.height, n = 512
        var out = after
        for (k, f) in faces.enumerated() {
            guard let (T0, side) = align(f, W, H, Double(n)), side * Double(scale) >= 200 else { continue }
            let T = CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(T0)
            let verdict: (Float, [Float])? = memo.value("guard.\(level.rawValue).\(k)") { () -> (Float, [Float])? in
                self.judge(before, after, T, st)
            }
            guard let (keep, m) = verdict else { continue }
            let mask = grey(m, n, n).clampedToExtent().transformed(by: T.inverted()).cropped(to: e)
            out = K.mixAmt.apply(extent: e, arguments: [out, before, mask, 1 - keep])!
        }
        return out
    }

    /// beautify.judge for one face: (how much of the change to keep, where to take it back: 512² mask), or nil when
    /// the face is not judged or within the limit.
    private func judge(_ before: CIImage, _ after: CIImage, _ T: CGAffineTransform, _ st: Strength) -> (Float, [Float])? {
        guard let critic else { return nil }
        let n = 512
        do {
            let xi = warp(before, T, n), yi = warp(after, T, n)
            var xa = [Float](repeating: 0, count: n * n * 4), ya = xa
            context.render(xi, toBitmap: &xa, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
            context.render(yi, toBitmap: &ya, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
            let N = n * n
            // skin_of: skin-coloured pixels (YCrCb) inside the face oval
            var w = [Float](repeating: 0, count: N)
            for i in 0..<N {
                let r = xa[i * 4], g = xa[i * 4 + 1], b = xa[i * 4 + 2]
                let Y = 0.299 * r + 0.587 * g + 0.114 * b
                let cr = ((r - Y) * 0.713 + 0.5) * 255, cb = ((b - Y) * 0.564 + 0.5) * 255
                let c01 = { (v: Float) in min(max(v, 0), 1) }
                let m = c01((cr - 128) / 8) * c01((185 - cr) / 8) * c01((cb - 70) / 8) * c01((134 - cb) / 8) * c01((Y - 0.06) / 0.1)
                let xx = Float(i % n) / Float(n), yy = Float(i / n) / Float(n)
                let oval = c01(1.6 - 1.6 * (pow((xx - 0.5) / 0.30, 2) + pow((yy - 0.56) / 0.40, 2)).squareRoot())
                w[i] = m * oval
            }
            if w.reduce(0, +) / Float(N) < 0.03 { return nil }
            let face = Float(n) * 0.5
            // colour layer of the change, and its local part
            var low = [[Float]](), local = [[Float]](), hx = [[Float]](), hy = [[Float]]()
            for c in 0..<3 {
                var dlt = (0..<N).map { ya[$0 * 4 + c] - xa[$0 * 4 + c] }
                dlt = gblur(dlt, n, face * Float(Self.SPLIT))
                let wide = gblur(dlt, n, face * 0.06)
                low.append(dlt); local.append(zip(dlt, wide).map { $0 - $1 })
                let xc = (0..<N).map { xa[$0 * 4 + c] }, yc = (0..<N).map { ya[$0 * 4 + c] }
                hx.append(zip(xc, gblur(xc, n, face * Float(Self.SPLIT))).map { $0 - $1 })
                hy.append(zip(yc, gblur(yc, n, face * Float(Self.SPLIT))).map { $0 - $1 })
            }
            // corrected: strong local changes (blemishes) and what is right next to them
            var marks = (0..<N).map { i in min(max(((abs(local[0][i]) + abs(local[1][i]) + abs(local[2][i])) / 3 * 255 - 3) / 3, 0), 1) }
            marks = dilate(marks, n, max(3, Int(face * 0.03)) | 1)
            marks = gblur(marks, n, face * 0.01)
            for i in 0..<N { w[i] *= 1 - marks[i] }
            let total = w.reduce(0, +)
            if total / Float(N) < 0.02 { return nil }
            var colour: Float = 0, ex: Float = 0, ey: Float = 0
            for i in 0..<N {
                colour += (abs(local[0][i]) + abs(local[1][i]) + abs(local[2][i])) / 3 * w[i]
                ex += (hx[0][i] * hx[0][i] + hx[1][i] * hx[1][i] + hx[2][i] * hx[2][i]) / 3 * w[i]
                ey += (hy[0][i] * hy[0][i] + hy[1][i] * hy[1][i] + hy[2][i] * hy[2][i]) / 3 * w[i]
            }
            colour = colour / (total + 1e-6) * 255
            let texture = 1 - (ey / (ex + 1e-9)).squareRoot()
            // what the critic expects professionals to do on this face (90th percentile)
            let V = 224
            let view = xi.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(V) / CGFloat(n), kCIInputAspectRatioKey: 1])
            var vp = [Float](repeating: 0, count: V * V * 4)
            context.render(view, toBitmap: &vp, rowBytes: V * 16, bounds: CGRect(x: 0, y: 0, width: V, height: V), format: .RGBAf, colorSpace: nil)
            guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: V), NSNumber(value: V)], dataType: .float32) else { return nil }
            let ip = input.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<(V * V) { for c in 0..<3 { ip[c * V * V + i] = min(max(vp[i * 4 + c], 0), 1) } }
            guard let r = try? critic.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
                  let q = r.featureValue(for: "q")?.multiArrayValue else { return nil }
            let qs = MLShapedArray<Float>(converting: q).scalars
            let qc = exp(qs[1]) - 0.1, qt = qs[3]
            let over = max(colour / ((Self.COLOUR_LIMIT.0 + Self.COLOUR_LIMIT.1 * st.smooth) * max(qc, 0.3)), texture / (Self.TEXTURE_LIMIT * max(qt, 0.03)))
            let keep = over <= 1 ? 1 : max(0.5, 1 / over)
            if Beauty.debugDir != nil { print(String(format: "  guard: colour %.2f texture %.3f expected %.2f %.3f over %.2f kept %.2f", colour, texture, qc, qt, over, keep)) }
            guard keep < 1 else { return nil }
            var m = [Float](repeating: 0, count: N)
            for i in 0..<N {
                let x = Float(i % n), y = Float(i / n)
                let rr = (pow((x - 255.5) / 176, 2) + pow((y - 272) / 224, 2)).squareRoot()
                m[i] = min(max((1 - rr) / 0.25, 0), 1) * (1 - marks[i])
            }
            return (keep, m)
        }
    }

    /// Gaussian blur of an n×n plane (cv2.GaussianBlur, edges extended).
    private func gblur(_ a: [Float], _ n: Int, _ sigma: Float) -> [Float] {
        guard sigma >= 0.3 else { return a }
        var src = a, dst = [Float](repeating: 0, count: a.count)
        let k = gaussianKernel(sigma)
        src.withUnsafeMutableBufferPointer { sb in dst.withUnsafeMutableBufferPointer { db in k.withUnsafeBufferPointer { kb in
            var s = vImage_Buffer(data: sb.baseAddress!, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
            var d = vImage_Buffer(data: db.baseAddress!, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
            _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, kb.baseAddress!, UInt32(kb.count), kb.baseAddress!, UInt32(kb.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
        } } }
        return dst
    }
    private func dilate(_ a: [Float], _ w: Int, _ h: Int, _ k: Int) -> [Float] {
        var src = a, dst = [Float](repeating: 0, count: a.count)
        src.withUnsafeMutableBufferPointer { sb in dst.withUnsafeMutableBufferPointer { db in
            var s = vImage_Buffer(data: sb.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var d = vImage_Buffer(data: db.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageMax_PlanarF(&s, &d, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageEdgeExtend))
        } }
        return dst
    }
    /// Maximum over a k×k square (cv2.dilate with np.ones).
    private func dilate(_ a: [Float], _ n: Int, _ k: Int) -> [Float] {
        var src = a, dst = [Float](repeating: 0, count: a.count)
        src.withUnsafeMutableBufferPointer { sb in dst.withUnsafeMutableBufferPointer { db in
            var s = vImage_Buffer(data: sb.baseAddress!, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
            var d = vImage_Buffer(data: db.baseAddress!, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 4)
            _ = vImageMax_PlanarF(&s, &d, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageEdgeExtend))
        } }
        return dst
    }
    private func morph(_ i: CIImage, _ r: CGFloat, max: Bool) -> CIImage {
        guard r >= 1 else { return i }
        return i.clampedToExtent().applyingFilter(max ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: i.extent)
    }

    // MARK: helpers

    private func blur(_ i: CIImage, _ s: CGFloat) -> CIImage {
        s < 0.3 ? i : i.clampedToExtent().applyingGaussianBlur(sigma: Double(s)).cropped(to: i.extent)
    }
    private func scaled(_ i: CIImage, _ d: CGFloat) -> CIImage {
        guard d < 1 else { return i }
        let o = i.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: d, kCIInputAspectRatioKey: 1])
        return o
    }
    /// A small copy back to the crop's size (bilinear, like cv2.resize INTER_LINEAR).
    private func up(_ i: CIImage, _ R: CGRect) -> CIImage {
        let s = i.extent
        guard abs(s.width - R.width) > 0.5 || abs(s.height - R.height) > 0.5 else { return i.cropped(to: R) }
        let t = CGAffineTransform(translationX: -s.minX, y: -s.minY)
            .concatenating(CGAffineTransform(scaleX: R.width / s.width, y: R.height / s.height))
            .concatenating(CGAffineTransform(translationX: R.minX, y: R.minY))
        return i.clampedToExtent().transformed(by: t).cropped(to: R)
    }
    private func open(_ i: CIImage, _ r: CGFloat) -> CIImage {
        guard r >= 1 else { return i }
        let mn = i.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
        return mn.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: i.extent)
    }
}

private func fill(_ ctx: CGContext, _ pts: [CGPoint]) {
    guard let f = pts.first else { return }
    ctx.beginPath(); ctx.move(to: f); for p in pts.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.fillPath()
}

/// Convex hull (monotone chain).
private func hull(_ p: [CGPoint]) -> [CGPoint] {
    let s = p.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    guard s.count > 2 else { return s }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lo: [CGPoint] = [], hi: [CGPoint] = []
    for q in s { while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], q) <= 0 { lo.removeLast() }; lo.append(q) }
    for q in s.reversed() { while hi.count >= 2 && cross(hi[hi.count - 2], hi[hi.count - 1], q) <= 0 { hi.removeLast() }; hi.append(q) }
    return Array(lo.dropLast() + hi.dropLast())
}

/// Masks drawn with Core Graphics over one crop at a reduced scale, then grown, feathered and laid over the crop.
struct Canvas {
    let R: CGRect
    let scale: CGFloat
    init(_ R: CGRect, scale: CGFloat) { self.R = R; self.scale = scale }

    /// `draw` gets a context (white on black) and a function from picture pixels to canvas pixels.
    /// `small`: leave it at the canvas scale (for work on a small copy whose extent is R × scale).
    func mask(grow: CGFloat = 0, blur: CGFloat = 0, small: Bool = false, _ draw: (CGContext, (CGPoint) -> CGPoint) -> Void) -> CIImage {
        let w = max(1, Int((R.width * scale).rounded(.up))), h = max(1, Int((R.height * scale).rounded(.up)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        draw(ctx) { CGPoint(x: ($0.x - R.minX) * scale, y: ($0.y - R.minY) * scale) }
        var m = CIImage(cgImage: ctx.makeImage()!, options: [.colorSpace: NSNull()])
        let ext = m.extent
        if grow * scale >= 1 {
            m = m.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: (grow * scale).rounded()]).cropped(to: ext)
        }
        if blur * scale > 0.3 { m = m.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale)).cropped(to: ext) }
        if small { return m.transformed(by: CGAffineTransform(translationX: R.minX * scale, y: R.minY * scale)) }
        return m.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(CGAffineTransform(translationX: R.minX, y: R.minY)))
            .cropped(to: R)
    }
}

/// Core Image kernels of the retouching. Masks are grey images (r = g = b); colours are sRGB-encoded numbers.
private enum K {
    static func c(_ s: String) -> CIColorKernel { CIColorKernel(source: s)! }
    static let zero = c("kernel vec4 z() { return vec4(0.0, 0.0, 0.0, 1.0); }")
    static let mul = c("kernel vec4 m(__sample a, __sample b) { return vec4(a.rgb * b.r, 1.0); }")
    static let add = c("kernel vec4 a(__sample a, __sample b) { return vec4(a.rgb + b.rgb, 1.0); }")
    static let sub = c("kernel vec4 s(__sample a, __sample b) { return vec4(a.rgb - b.rgb, 1.0); }")
    static let subPos = c("kernel vec4 s(__sample a, __sample b) { return vec4(max(a.rgb - b.rgb, 0.0), 1.0); }")
    static let invert = c("kernel vec4 i(__sample a) { return vec4(1.0 - a.rgb, 1.0); }")
    static let clamp = c("kernel vec4 c(__sample a) { return vec4(clamp(a.rgb, 0.0, 1.0), 1.0); }")
    static let lin = c("kernel vec4 l(__sample a, float k, float o) { return vec4(clamp(a.rgb * k + o, 0.0, 1.0), 1.0); }")
    static let divide = c("kernel vec4 d(__sample a, __sample n) { return vec4(a.rgb / (n.r + 0.001), 1.0); }")
    static let mix = c("kernel vec4 x(__sample a, __sample b, __sample m) { return vec4(mix(a.rgb, b.rgb, m.r), a.a); }")
    static let mixAmt = c("kernel vec4 x(__sample a, __sample b, __sample m, float k) { return vec4(a.rgb + k * m.r * (b.rgb - a.rgb), 1.0); }")
    static let addMasked = c("kernel vec4 x(__sample a, __sample d, __sample m, float k) { return vec4(a.rgb + k * m.r * d.rgb, a.a); }")
    static let skinPrep = c("kernel vec4 s(__sample s, __sample f) { float v = s.r * (1.0 - f.r); return vec4(v, v, v, 1.0); }")
    static let fade = c("""
        kernel vec4 f(vec4 R, float r, vec4 on) {
          vec2 p = destCoord();
          float v = 1.0;
          if (on.x > 0.5) v *= clamp((p.x - R.x) / r, 0.0, 1.0);
          if (on.y > 0.5) v *= clamp((R.x + R.z - p.x) / r, 0.0, 1.0);
          if (on.z > 0.5) v *= clamp((p.y - R.y) / r, 0.0, 1.0);
          if (on.w > 0.5) v *= clamp((R.y + R.w - p.y) / r, 0.0, 1.0);
          return vec4(v, v, v, 1.0);
        }
        """)
    // OpenCV's float RGB -> Lab (sRGB gamma, D65): L 0..100
    static let rgb2lab = c("""
        float lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((max(c, 0.0) + 0.055) / 1.055, 2.4); }
        float ff(float t) { return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0; }
        kernel vec4 l(__sample s) {
          vec3 c = vec3(lin(s.r), lin(s.g), lin(s.b));
          float X = dot(c, vec3(0.412453, 0.357580, 0.180423)) / 0.950456;
          float Y = dot(c, vec3(0.212671, 0.715160, 0.072169));
          float Z = dot(c, vec3(0.019334, 0.119193, 0.950227)) / 1.088754;
          float L = Y > 0.008856 ? 116.0 * pow(Y, 1.0 / 3.0) - 16.0 : 903.3 * Y;
          return vec4(L, 500.0 * (ff(X) - ff(Y)), 200.0 * (ff(Y) - ff(Z)), 1.0);
        }
        """)
    static let lab2rgb = c("""
        float enc(float c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055; }
        float fi(float t) { return t > 0.206893 ? t * t * t : (t - 16.0 / 116.0) / 7.787; }
        kernel vec4 r(__sample l) {
          float fy = (l.r + 16.0) / 116.0;
          float X = fi(fy + l.g / 500.0) * 0.950456, Y = fi(fy), Z = fi(fy - l.b / 200.0) * 1.088754;
          vec3 c = vec3(dot(vec3(X, Y, Z), vec3(3.240479, -1.53715, -0.498535)),
                        dot(vec3(X, Y, Z), vec3(-0.969256, 1.875991, 0.041556)),
                        dot(vec3(X, Y, Z), vec3(0.055648, -0.204043, 1.057311)));
          return vec4(enc(c.r), enc(c.g), enc(c.b), 1.0);
        }
        """)
    // surrounding skin = average of skin that is not itself a spot
    static let keep = c("kernel vec4 k(__sample l, __sample a, __sample w) { float red = l.g - a.g; float v = w.r * clamp(1.0 - (red - 1.5) / 3.0, 0.05, 1.0); return vec4(v, v, v, 1.0); }")
    static let spot = c("""
        kernel vec4 s(__sample l, __sample a, __sample w) {
          float red = l.g - a.g;
          float v = clamp((red - 1.5) / 3.0, 0.0, 1.0) * w.r * clamp(1.0 - (a.r - l.r - 10.0) / 8.0, 0.0, 1.0);
          return vec4(v, v, v, 1.0);
        }
        """)
    static let yellow = c("kernel vec4 y(__sample l, __sample a) { return vec4(l.b - a.b, max(l.g - a.g, 0.0), a.r - l.r, 1.0); }")
    static let inflame = c("""
        kernel vec4 i(__sample s, __sample w, __sample y, __sample p, __sample nz) {
          float more = y.r / (y.g + 0.5);
          float inf = clamp((0.35 - more) / 0.2, 0.0, 1.0) * clamp(y.b / 2.0, 0.0, 1.0);
          float v = mix(s.r - w.r + w.r * inf, max(s.r - p.r, 0.0), clamp(nz.r, 0.0, 1.0));
          return vec4(v, v, v, 1.0);
        }
        """)
    static let bump = c("kernel vec4 b(__sample l, __sample a, __sample n, __sample w) { float v = clamp((abs(l.r - a.r) - 2.0) / 4.0, 0.0, 1.0) * n.r * w.r; return vec4(v, v, v, 1.0); }")
    static let glare = c("""
        kernel vec4 g(__sample l, __sample a, __sample w) {
          float ch = length(l.gb), cha = length(a.gb);
          float v = clamp((l.r - a.r - 5.0) / 9.0, 0.0, 1.0) * clamp((cha - ch) / 3.0, 0.0, 1.0) * w.r;
          return vec4(v, v, v, 1.0);
        }
        """)
    static let fix = c("""
        kernel vec4 f(__sample l, __sample a, __sample s, __sample b, __sample g, float ks, float kr, float kg) {
          vec3 o = l.rgb + ks * s.r * (a.rgb - l.rgb);
          o.r += kr * b.r * (a.r - l.r);
          o += kg * g.r * (a.rgb - o);
          return vec4(o, 1.0);
        }
        """)
    static let marks = c("kernel vec4 m(__sample s, __sample b, __sample o, float k) { float v = clamp(s.r + k * b.r, 0.0, 1.0) * o.r; return vec4(v, v, v, 1.0); }")
    static let high = c("kernel vec4 h(__sample c, __sample lo, __sample m, float k) { return vec4((c.rgb - lo.rgb) * (1.0 - k * m.r), 1.0); }")
    static let glint = c("""
        kernel vec4 g(__sample h, __sample c, __sample o, float k) {
          float peak = (h.r + h.g + h.b) / 3.0;
          float top = max(c.r, max(c.g, c.b)), bot = min(c.r, min(c.g, c.b));
          float pale = clamp((0.40 - (top - bot) / (top + 0.0001)) / 0.2, 0.0, 1.0);
          float gl = clamp((peak - 0.04) / 0.06, 0.0, 1.0) * pale * o.r;
          return vec4(h.rgb - k * gl * max(h.rgb, 0.0), 1.0);
        }
        """)
    static let underMask = c("kernel vec4 u(__sample u, __sample e, __sample s) { float v = u.r * (1.0 - e.r) * clamp(s.r * 2.0, 0.0, 1.0); return vec4(v, v, v, 1.0); }")
    // The under-eye area is moved towards the cheek below (in Lab). On a made-up face (mk: Face.makeup; the user's photos:
    // blush high under the eyes, 卧蚕 highlight) it is only lifted and warmed - never darkened, never made less red or
    // less yellow: dark circles are still corrected, blush and highlighter there are left as they are.
    static let underEye = c("""
        float lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((max(c, 0.0) + 0.055) / 1.055, 2.4); }
        float ff(float t) { return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0; }
        vec3 toLab(vec3 s) {
          vec3 c = vec3(lin(s.r), lin(s.g), lin(s.b));
          float X = dot(c, vec3(0.412453, 0.357580, 0.180423)) / 0.950456;
          float Y = dot(c, vec3(0.212671, 0.715160, 0.072169));
          float Z = dot(c, vec3(0.019334, 0.119193, 0.950227)) / 1.088754;
          float L = Y > 0.008856 ? 116.0 * pow(Y, 1.0 / 3.0) - 16.0 : 903.3 * Y;
          return vec3(L, 500.0 * (ff(X) - ff(Y)), 200.0 * (ff(Y) - ff(Z)));
        }
        float enc(float c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055; }
        float fi(float t) { return t > 0.206893 ? t * t * t : (t - 16.0 / 116.0) / 7.787; }
        vec3 toRGB(vec3 l) {
          float fy = (l.x + 16.0) / 116.0;
          float X = fi(fy + l.y / 500.0) * 0.950456, Y = fi(fy), Z = fi(fy - l.z / 200.0) * 1.088754;
          vec3 c = vec3(dot(vec3(X, Y, Z), vec3(3.240479, -1.53715, -0.498535)),
                        dot(vec3(X, Y, Z), vec3(-0.969256, 1.875991, 0.041556)),
                        dot(vec3(X, Y, Z), vec3(0.055648, -0.204043, 1.057311)));
          return vec3(enc(c.r), enc(c.g), enc(c.b));
        }
        kernel vec4 u(__sample lo, __sample m, __sample cb, __sample c, __sample ub, __sample u, __sample lc, float k, float area, float mk) {
          if (c.r * area < 10.0 || u.r * area < 10.0 || m.r <= 0.0) return lo;
          vec3 ck = toLab(cb.rgb / c.r);
          vec3 d = ck - toLab(ub.rgb / u.r);                       // colour: the area's mean towards the cheek's
          d.x = max(ck.x - toLab(lc.rgb).x, 0.0);                  // lightness: each place by how much darker it is than the cheek
          d = mix(d, max(d, 0.0), mk);
          return vec4(toRGB(toLab(lo.rgb) + k * m.r * d), 1.0);
        }
        """)
    static let eyes = c("kernel vec4 e(__sample o, __sample c, __sample b, __sample m, float k) { return vec4(o.rgb + k * m.r * (0.6 * (c.rgb - b.rgb) + 0.03), 1.0); }")
    static let teeth = c("""
        kernel vec4 t(__sample o, __sample c, __sample m, float k) {
          float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
          float sat = (mx - mn) / (mx + 0.0001);
          float t = m.r * clamp((mx - 0.35) * 5.0, 0.0, 1.0) * clamp((0.45 - sat) * 6.0, 0.0, 1.0);
          float g = (o.r + o.g + o.b) / 3.0;
          return vec4(o.rgb + k * t * (0.5 * (g - o.rgb) + 0.05), 1.0);
        }
        """)
    static let bandOff = c("kernel vec4 b(__sample s, __sample k, __sample z, float mk) { float v = s.r * (1.0 - max(clamp(z.r, 0.0, 1.0), mk) * (1.0 - k.r)); return vec4(v, v, v, 1.0); }")
    static let maxOf = c("kernel vec4 m(__sample a, __sample b) { return vec4(max(a.rgb, b.rgb), 1.0); }")
    static let mul3 = c("kernel vec4 m(__sample a, __sample g) { return vec4(a.rgb * g.r, a.a); }")
    static let lineWhere = c("kernel vec4 w(__sample s, __sample k) { float v = clamp(s.r * 1.5, 0.0, 1.0) * (1.0 - clamp(k.r * 1.5, 0.0, 1.0)); return vec4(v, v, v, 1.0); }")
    static let luma = c("kernel vec4 l(__sample a) { float v = dot(a.rgb, vec3(0.299, 0.587, 0.114)); return vec4(v, v, v, 1.0); }")
    static let mean = c("kernel vec4 l(__sample a) { float v = (a.r + a.g + a.b) / 3.0; return vec4(v, v, v, 1.0); }")
    static let depth = c("kernel vec4 d(__sample f, __sample n) { float v = (f.r - n.r) / (f.r + 0.05); return vec4(v, v, v, 1.0); }")
    static let line = c("""
        kernel vec4 l(__sample d, __sample g, __sample m, vec4 L) {
          float v = clamp((d.r - L.x) / (L.y - L.x), 0.0, 1.0) * clamp(g.r * 1.6 - 0.3, 0.0, 1.0) * clamp(1.0 - (m.r - L.z) / (L.w - L.z), 0.0, 1.0);
          return vec4(v, v, v, 1.0);
        }
        """)
    static let lineGain = c("kernel vec4 g(__sample l, __sample f, __sample n, float k) { float v = 1.0 + k * l.r * (f.r - n.r) / (n.r + 0.02); return vec4(v, v, v, 1.0); }")
    static let hess = CIKernel(source: """
        kernel vec4 h(sampler b) {
          vec2 d = destCoord();
          float p[9];
          for (int j = 0; j < 3; j++) { for (int i = 0; i < 3; i++) { p[j * 3 + i] = sample(b, samplerTransform(b, d + vec2(float(i - 1), float(j - 1)))).r; } }
          float xx = (p[0] - 2.0 * p[1] + p[2]) + 2.0 * (p[3] - 2.0 * p[4] + p[5]) + (p[6] - 2.0 * p[7] + p[8]);
          float yy = (p[0] - 2.0 * p[3] + p[6]) + 2.0 * (p[1] - 2.0 * p[4] + p[7]) + (p[2] - 2.0 * p[5] + p[8]);
          float xy = p[0] - p[2] - p[6] + p[8];
          float root = sqrt(0.25 * (xx - yy) * (xx - yy) + xy * xy);
          float across = 0.5 * (xx + yy) + root, along = 0.5 * (xx + yy) - root;
          float v = across > 0.0 ? clamp(1.0 - abs(along) / (across + 0.0001), 0.0, 1.0) : 0.0;
          return vec4(v, v, v, 1.0);
        }
        """)!
    /// Where a valley is long rather than round (curvature across it vs along it), from second derivatives (Sobel 3×3).
    static func hessian(_ i: CIImage) -> CIImage {
        hess.apply(extent: i.extent, roiCallback: { _, r in r.insetBy(dx: -1, dy: -1) }, arguments: [i.clampedToExtent()])!.cropped(to: i.extent)
    }
    static let lineResp = CIKernel(source: """
        kernel vec4 l(sampler h, float c) {
          vec2 d = destCoord(); float best = 0.0;
          for (int t = 0; t < 12; t++) {
            float a = 3.14159265 * float(t) / 12.0; vec2 dir = vec2(cos(a), sin(a));
            float s = 0.0, k = 0.0;
            for (float u = -c; u <= c + 0.01; u += 1.0) { s += sample(h, samplerTransform(h, d + dir * u)).r; k += 1.0; }
            best = max(best, -s / k);
          }
          return vec4(best, best, best, 1.0);
        }
        """)!
    /// The strongest dark line through each pixel: the texture layer averaged along segments of 2c+1 pixels in 12 directions.
    static func lineResponse(_ i: CIImage, _ c: CGFloat) -> CIImage {
        lineResp.apply(extent: i.extent, roiCallback: { _, r in r.insetBy(dx: -c - 1, dy: -c - 1) }, arguments: [i.clampedToExtent(), c])!.cropped(to: i.extent)
    }
    static let hair = c("""
        kernel vec4 h(__sample d, __sample s, float noise, float k, float span) {
          float lo = max(noise, k * (s.r + 0.1));
          float v = clamp((d.r - lo) / (lo * span), 0.0, 1.0);
          return vec4(v, v, v, 1.0);
        }
        """)
    static let even = c("kernel vec4 e(__sample o, __sample b, __sample l, __sample p, __sample h, float k) { return vec4(o.rgb + k * p.r * (1.0 - clamp(h.r, 0.0, 1.0)) * (b.rgb - l.rgb), o.a); }")
    static let notNear = c("kernel vec4 n(__sample w, __sample k) { float v = w.r * clamp(1.0 - 1.6 * k.r, 0.0, 1.0); return vec4(v, v, v, 1.0); }")
    static let shiftAB = c("kernel vec4 s(__sample l, __sample m, float a, float b) { return vec4(l.r, l.g + m.r * a, l.b + m.r * b, 1.0); }")
    static let bilat = CIKernel(source: """
        kernel vec4 bilat(sampler src, float r, float ss, float sc) {
          vec2 dc = destCoord(); vec4 c0 = sample(src, samplerTransform(src, dc));
          vec3 acc = vec3(0.0); float ws = 0.0;
          for (float y = -r; y <= r; y += 1.0) { for (float x = -r; x <= r; x += 1.0) {
            if (x * x + y * y > r * r) continue;
            vec4 c = sample(src, samplerTransform(src, dc + vec2(x, y)));
            vec3 d = abs(c.rgb - c0.rgb); float cd = d.r + d.g + d.b;
            float w = exp(-(x * x + y * y) / (2.0 * ss * ss) - cd * cd / (2.0 * sc * sc));
            acc += w * c.rgb; ws += w; } }
          return vec4(acc / ws, 1.0);
        }
        """)!
    /// cv2.bilateralFilter(src, -1, sc, ss): circular window of radius round(1.5 ss), colour distance = sum of |differences|.
    static func bilateral(_ i: CIImage, radius: CGFloat, ss: CGFloat, sc: CGFloat) -> CIImage {
        let r = max(1, radius)
        return bilat.apply(extent: i.extent, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) },
                           arguments: [i.clampedToExtent(), r, ss, sc])!.cropped(to: i.extent)
    }
}

/// Measurements of one photo under one look that do not change between renders (see Beauty.apply).
final class BeautyMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]
    func value<T>(_ key: String, _ make: () -> T) -> T {
        lock.lock()
        if let any = store[key], let v = any as? T { lock.unlock(); return v }     // (a missing key is not a stored nil)
        lock.unlock()
        let v = make()
        lock.lock(); store[key] = v; lock.unlock()
        return v
    }
    /// A new memo with only the given measurements (those that do not depend on the picture's size: for the export).
    func keeping(_ keys: [String]) -> BeautyMemo {
        let m = BeautyMemo()
        lock.lock(); for k in keys { if let v = store[k] { m.store[k] = v } }; lock.unlock()
        return m
    }
}
