import CoreImage
import Foundation
import simd
import Vision

/// 塑形 and 匀光, ported from the Mac pipeline (lrcdf/shape.py, the strengths of plug-in Config.shapes): geometry only,
/// worked out once per photo on a small grid and applied to the preview and the full-size export alike (offsets are
/// stored as fractions of the picture width). Each step is skipped when it cannot be done safely - body turned away, an
/// arm in front, legs not in the picture - exactly as on the Mac.
///
/// What the iPad does differently: faces come from Vision's landmarks (jaw outline, eyes) instead of MediaPipe's mesh,
/// bodies from Vision's body pose and person segmentation instead of MediaPipe's pose model, and 匀光 evens the light
/// across the face with a smooth fitted ramp (the Mac fits light to the mesh's depth, which Vision does not give).
struct ShapeSet: Equatable, Hashable {
    var slim = false, eyes = false, waist = false, chest = false, legs = false, light = false
    var any: Bool { slim || eyes || waist || chest || legs || light }
    var key: String { [slim, eyes, waist, chest, legs, light].map { $0 ? "1" : "0" }.joined() }
    // the Mac's strengths (Config.shapes, percent)
    static let amount: [String: Float] = ["slim": 0.6, "eyes": 0.7, "chest": 0.7, "waist": 0.7, "legs": 0.8, "light": 0.7]
}

/// One person's body as Vision sees it: joints in picture pixels (Core Image: origin bottom-left) with confidence.
struct Body {
    var joints: [VNHumanBodyPoseObservation.JointName: (CGPoint, Float)]
    func p(_ j: VNHumanBodyPoseObservation.JointName) -> SIMD2<Float>? {
        guard let (pt, c) = joints[j], c > 0.3 else { return nil }
        return SIMD2(Float(pt.x), Float(pt.y))
    }
    func conf(_ j: VNHumanBodyPoseObservation.JointName) -> Float { joints[j]?.1 ?? 0 }
}

/// Bodies and the people mask of a picture (found once per photo, on the preview).
struct People {
    var bodies: [Body]
    var mask: [Float]          // people (1) / not (0), `mw` × `mh`, top row = top of the picture
    var mw = 0, mh = 0
    var size: CGSize           // the picture these were found on

    static func find(_ cg: CGImage) -> People {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        let pose = VNDetectHumanBodyPoseRequest()
        let seg = VNGeneratePersonSegmentationRequest(); seg.qualityLevel = .balanced; seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler.perform([pose, seg])
        var bodies: [Body] = []
        for o in pose.results ?? [] {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            var j: [VNHumanBodyPoseObservation.JointName: (CGPoint, Float)] = [:]
            for (k, v) in pts where v.confidence > 0 { j[k] = (CGPoint(x: v.location.x * W, y: v.location.y * H), v.confidence) }
            bodies.append(Body(joints: j))
        }
        var mask: [Float] = [], mw = 0, mh = 0
        if let pb = seg.results?.first?.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            mw = CVPixelBufferGetWidth(pb); mh = CVPixelBufferGetHeight(pb)
            let row = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            mask = [Float](repeating: 0, count: mw * mh)
            for y in 0..<mh { for x in 0..<mw { mask[y * mw + x] = Float(base[y * row + x]) / 255 } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        return People(bodies: bodies, mask: mask, mw: mw, mh: mh, size: CGSize(width: W, height: H))
    }

    /// The mask at a picture point (Core Image pixels of the picture the people were found on).
    func inside(_ p: SIMD2<Float>) -> Float {
        guard mw > 0 else { return 1 }
        let x = Int(p.x / Float(size.width) * Float(mw)), y = Int((1 - p.y / Float(size.height)) * Float(mh))
        guard x >= 0, y >= 0, x < mw, y < mh else { return 0 }
        return mask[y * mw + x]
    }
}

/// Where each pixel of the result comes from: offsets on a small grid, as fractions of the picture width,
/// result (x, y) <- source (x + dx·W, y + dy·W), Core Image coordinates (y up).
struct ShapePlan {
    var dx: [Float], dy: [Float]
    var gw: Int, gh: Int
    var notes: [String]
}

enum Shaping {
    static let SLIM: Float = 0.05, EYES: Float = 0.10, WAIST: Float = 0.055, CHEST: Float = 0.16, LEGS: Float = 0.07

    /// `faces` and `people` found on a picture of `size`; nil when nothing would move.
    static func plan(size: CGSize, faces: [Face], people: People?, set: ShapeSet, men: Bool) -> ShapePlan? {
        let W = Float(size.width), H = Float(size.height)
        let s = min(1, 384 / max(W, H))
        let gw = max(2, Int((W * s).rounded())), gh = max(2, Int((H * s).rounded()))
        var fx = [Float](repeating: 0, count: gw * gh), fy = fx
        var notes: [String] = []
        // grid point (i, j) = picture point (i / s, j / s), j counted from the bottom (Core Image)
        func addGauss(_ c: SIMD2<Float>, _ sigma: Float, _ move: SIMD2<Float>, weight: inout [Float], acc: inout [SIMD2<Float>]) {
            let r = Int(3 * sigma * s) + 1, ci = Int(c.x * s), cj = Int(c.y * s)
            for j in max(0, cj - r)..<min(gh, cj + r) { for i in max(0, ci - r)..<min(gw, ci + r) {
                let px = Float(i) / s - c.x, py = Float(j) / s - c.y
                let g = expf(-(px * px + py * py) / (2 * sigma * sigma))
                weight[j * gw + i] += g; acc[j * gw + i] += g * move
            } }
        }
        func pt(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x) * W, Float(p.y) * H) }

        // face: the jaw outline pulled towards the face's midline; eyes magnified at their centre
        for f in faces where f.mesh {
            let fw = Float(f.width) * W
            if set.slim, f.lipsOut.count > 2, f.eyeL.count > 2 {
                let mid = { (ps: [CGPoint]) -> SIMD2<Float> in ps.map(pt).reduce(SIMD2<Float>(0, 0), +) / Float(ps.count) }
                let top = (mid(f.eyeL) + mid(f.eyeR)) / 2, chin = mid(f.lipsOut)
                let axis = simd_normalize(chin - top)
                let outline = f.box.width > 0 ? jaw(f).map(pt) : []
                var weight = [Float](repeating: 0, count: gw * gh), acc = [SIMD2<Float>](repeating: .zero, count: gw * gh)
                let n = outline.count
                for (k, p) in outline.enumerated() {
                    // strongest at the jaw angle (a third and two thirds of the way along), fading to ears and chin
                    let t = Float(k) / Float(max(1, n - 1)), pull = max(0.15, 1 - abs(abs(t - 0.5) - 0.25) * 3.4)
                    let foot = top + simd_dot(p - top, axis) * axis, away = simd_length(foot - p)
                    guard away > 1, simd_dot(p - top, axis) > 0 else { continue }       // below the eyes only
                    let move = (foot - p) / away * SLIM * ShapeSet.amount["slim"]! * fw * pull * min(1, away / (0.25 * fw))
                    addGauss(p, fw * 0.1, move, weight: &weight, acc: &acc)
                }
                for k in 0..<(gw * gh) where weight[k] > 0 {
                    let m = acc[k] / max(weight[k], 1)
                    fx[k] -= m.x; fy[k] -= m.y
                }
                notes.append("slim")
            }
            if set.eyes {
                for eye in [f.eyeL, f.eyeR] where eye.count > 2 {
                    let ps = eye.map(pt), c = ps.reduce(SIMD2<Float>(0, 0), +) / Float(ps.count)
                    var width: Float = 0
                    for a in ps { for b in ps { width = max(width, simd_length(a - b)) } }
                    guard width >= fw * 0.08 else { continue }       // turned away from the camera
                    magnify(&fx, &fy, gw, gh, s, c, width * 1.05, ShapeSet.amount["eyes"]! * EYES)
                }
                notes.append("eyes")
            }
        }
        // body: waist pulled in at the outline, chest magnified
        if let people, set.waist || set.chest {
            for b in people.bodies {
                guard let t = torso(b) else { continue }
                if set.waist && people.mw > 0 {
                    let centre = t.ms + t.down * 0.68 * t.length
                    for side: Float in [-1, 1] {
                        var edge: SIMD2<Float>? = nil
                        var step: Float = 0.12
                        while step < 0.75 {
                            let p = centre + t.across * side * step * t.width
                            if people.inside(p) < 0.5 { edge = p; break }
                            step += 0.01
                        }
                        guard let e = edge, simd_length(e - centre) <= 0.62 * t.width, !armNear(b, e, 0.14 * t.width) else { continue }
                        let move = -t.across * side * ShapeSet.amount["waist"]! * WAIST * t.width
                        for j in 0..<gh { for i in 0..<gw {
                            let q = SIMD2(Float(i) / s, Float(j) / s) - e
                            let along = simd_dot(q, t.down), beside = simd_dot(q, t.across)
                            let g = expf(-powf(along / (0.20 * t.length), 2) - powf(beside / (0.16 * t.width), 2))
                            fx[j * gw + i] -= g * move.x; fy[j * gw + i] -= g * move.y
                        } }
                        notes.append("waist")
                    }
                }
                if set.chest && !men {
                    for side: Float in [-1, 1] {
                        let c = t.ms + t.down * 0.30 * t.length + t.across * side * 0.20 * t.width, radius = 0.21 * t.width
                        guard !armNear(b, c, radius * 1.3) else { continue }
                        magnify(&fx, &fy, gw, gh, s, c, radius, ShapeSet.amount["chest"]! * CHEST)
                        notes.append("chest")
                    }
                }
            }
        }
        // legs: standing people only, stretched upwards from the upper thigh, the top rows that leave are dropped
        if set.legs, let people, let rows = legs(people, H: H, gh: gh, s: s) {
            for j in 0..<gh { for i in 0..<gw { fy[j * gw + i] += rows[j] } }
            notes.append("legs")
        }
        var biggest: Float = 0
        for k in 0..<(gw * gh) { biggest = max(biggest, abs(fx[k]), abs(fy[k])) }
        guard biggest > 0.3 else { return nil }
        return ShapePlan(dx: fx.map { $0 / W }, dy: fy.map { $0 / W }, gw: gw, gh: gh, notes: notes)
    }

    /// Vision's face outline (ear, jaw, chin, jaw, ear) in normalised picture points, or nothing.
    static func jaw(_ f: Face) -> [CGPoint] { f.contour }

    private static func magnify(_ fx: inout [Float], _ fy: inout [Float], _ gw: Int, _ gh: Int, _ s: Float, _ c: SIMD2<Float>, _ radius: Float, _ k: Float) {
        let r = Int(radius * s) + 1, ci = Int(c.x * s), cj = Int(c.y * s)
        for j in max(0, cj - r)..<min(gh, cj + r) { for i in max(0, ci - r)..<min(gw, ci + r) {
            let dx = Float(i) / s - c.x, dy = Float(j) / s - c.y
            let inside = powf(max(0, 1 - (dx * dx + dy * dy) / (radius * radius)), 2)
            fx[j * gw + i] -= dx * k * inside; fy[j * gw + i] -= dy * k * inside
        } }
    }

    struct Torso { var ms, down, across: SIMD2<Float>; var width, length: Float }

    /// A torso seen from the front, or nil (shoulders/hips hidden, turned sideways, back to the camera).
    static func torso(_ b: Body) -> Torso? {
        guard let ls = b.p(.leftShoulder), let rs = b.p(.rightShoulder), let lh = b.p(.leftHip), let rh = b.p(.rightHip),
              min(b.conf(.leftShoulder), b.conf(.rightShoulder)) >= 0.5, min(b.conf(.leftHip), b.conf(.rightHip)) >= 0.3, b.conf(.nose) >= 0.3 else { return nil }   // Vision rates hips lower than MediaPipe (0.44 on a plain standing figure)
        let ms = (ls + rs) / 2, mh = (lh + rh) / 2
        let length = simd_length(mh - ms), width = simd_length(ls - rs)
        guard length >= 20, width / length >= 0.5, width / length <= 1.15 else { return nil }
        let down = (mh - ms) / length
        let rToL = ls - rs
        // from the front the person's left is on our right; with y pointing up the cross product's sign is the Mac's flipped
        guard rToL.x * down.y - rToL.y * down.x < 0 else { return nil }
        return Torso(ms: ms, down: down, across: SIMD2(-down.y, down.x), width: width, length: length)
    }

    static func armNear(_ b: Body, _ p: SIMD2<Float>, _ reach: Float) -> Bool {
        let arms: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] =
            [(.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist)]
        for (a, c) in arms {
            guard let pa = b.p(a), let pc = b.p(c) else { continue }
            let ab = pc - pa, t = max(0, min(1, simd_dot(p - pa, ab) / (simd_dot(ab, ab) + 1e-6)))
            if simd_length(p - (pa + t * ab)) < reach { return true }
        }
        for w in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] { if let pw = b.p(w), simd_length(pw - p) < reach { return true } }
        return false
    }

    /// Per grid row (from the bottom), how far down (in picture pixels, y up = negative) its source row lies.
    static func legs(_ people: People, H: Float, gh: Int, s: Float) -> [Float]? {
        var standing: [(Float, Float, Float)] = []         // hip, ankle, top of the person - measured from the TOP (y down)
        for b in people.bodies {
            guard let lh = b.p(.leftHip), let rh = b.p(.rightHip), let lk = b.p(.leftKnee), let rk = b.p(.rightKnee),
                  let la = b.p(.leftAnkle), let ra = b.p(.rightAnkle),
                  min(b.conf(.leftHip), b.conf(.rightHip), b.conf(.leftKnee), b.conf(.rightKnee), b.conf(.leftAnkle), b.conf(.rightAnkle)) >= 0.3 else { continue }
            let down = { (v: SIMD2<Float>) -> SIMD2<Float> in SIMD2(v.x, H - v.y) }
            let hip = (down(lh) + down(rh)) / 2, ankle = (down(la) + down(ra)) / 2, leg = ankle - hip
            guard leg.y >= 0.12 * H, abs(leg.x) <= 0.35 * leg.y else { continue }
            guard min(down(lk).y, down(rk).y) >= hip.y, max(down(lk).y, down(rk).y) <= ankle.y else { continue }
            let top = b.joints.values.filter { $0.1 > 0.3 }.map { H - Float($0.0.y) }.min() ?? hip.y
            standing.append((hip.y, ankle.y, max(0, top - 0.08 * H)))
        }
        guard !standing.isEmpty, standing.count == people.bodies.count else { return nil }
        var y0 = standing.map(\.0).reduce(0, +) / Float(standing.count)
        let y1 = standing.map(\.1).reduce(0, +) / Float(standing.count)
        guard standing.allSatisfy({ abs($0.0 - y0) <= 0.06 * H && abs($0.1 - y1) <= 0.06 * H }) else { return nil }
        y0 += 0.12 * (y1 - y0)
        let headroom = standing.map(\.2).min()! * 0.8
        let added = min(ShapeSet.amount["legs"]! * LEGS * (y1 - y0), headroom)
        guard added >= 0.004 * H else { return nil }
        let k = 1 + added / (y1 - y0)
        // source rows (y down, picture pixels) -> where they land; invert by interpolation
        let n = 2048
        let src = (0..<n).map { Float($0) / Float(n - 1) * H }
        let soft = max(2, 0.03 * (y1 - y0))
        let ramp = { (v: Float) -> Float in 1 / (1 + expf(-v)) }
        var pos = [Float](repeating: 0, count: n), acc: Float = 0
        let dsrc = H / Float(n - 1)
        for i in 0..<n { let sc = 1 + (k - 1) * ramp((src[i] - y0) / soft) * ramp((y1 - src[i]) / soft); acc += sc * dsrc; pos[i] = acc }
        let shift = pos[n - 1] - H
        for i in 0..<n { pos[i] -= shift }                      // the bottom row stays where it is
        var rows = [Float](repeating: 0, count: gh)
        for j in 0..<gh {
            let yUp = Float(j) / s, yDown = H - yUp           // result row (y down)
            var lo = 0, hi = n - 2                             // the source interval that lands on it (pos rises)
            while lo < hi { let m = (lo + hi + 1) / 2; if pos[m] <= yDown { lo = m } else { hi = m - 1 } }
            let i = lo
            let t = max(0, min(1, (yDown - pos[i]) / max(pos[i + 1] - pos[i], 1e-6)))
            let srcDown = src[i] + t * (src[i + 1] - src[i])
            rows[j] = -(srcDown - yDown)                         // y up: a source further down is a smaller y
        }
        return rows
    }

    private static let warp = CIKernel(source: """
        kernel vec4 w(sampler src, sampler field, float W, vec2 size) {
          vec2 d = destCoord();
          vec4 m = sample(field, samplerTransform(field, d));
          vec2 p = d + vec2(m.r, m.g) * W;
          return sample(src, samplerTransform(src, clamp(p, vec2(0.5), size - 0.5)));
        }
        """)!

    /// The picture moved as planned (any size: offsets scale with the width).
    static func apply(_ image: CIImage, _ plan: ShapePlan) -> CIImage {
        let e = image.extent
        var rgba = [Float](repeating: 0, count: plan.gw * plan.gh * 4)
        for j in 0..<plan.gh { for i in 0..<plan.gw {
            let k = j * plan.gw + i, row = plan.gh - 1 - j           // bitmap rows from the top
            rgba[(row * plan.gw + i) * 4] = plan.dx[k]; rgba[(row * plan.gw + i) * 4 + 1] = plan.dy[k]; rgba[(row * plan.gw + i) * 4 + 3] = 1
        } }
        let field = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: plan.gw * 16,
                            size: CGSize(width: plan.gw, height: plan.gh), format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(plan.gw), y: e.height / CGFloat(plan.gh)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        let moved = warp.apply(extent: e, roiCallback: { i, r in i == 0 ? e : field.extent },
                               arguments: [image.clampedToExtent(), field.clampedToExtent(), Float(e.width), CIVector(x: e.width, y: e.height)])!
        return moved.cropped(to: e)
    }

    // MARK: 匀光

    /// Evens the light across each face: the skin's brightness is fitted with a smooth ramp (left-right, top-bottom)
    /// over the face, and the picture's light layer is divided by most of it, never by more than the Mac's limits
    /// (0.72 … 1.45). Only brightness at a large scale changes: texture and colour stay. `enc`: sRGB numbers.
    static func evenLight(_ enc: CIImage, faces: [Face], amount: Float, context: CIContext) -> CIImage {
        let e = enc.extent, W = e.width, H = e.height
        var out = enc
        for f in faces {
            let box = CGRect(x: f.box.minX * W, y: f.box.minY * H, width: f.box.width * W, height: f.box.height * H)
            guard box.width > 60 else { continue }
            let n = 64
            var px = [Float](repeating: 0, count: n * n * 4)
            let crop = enc.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(n) / box.width, y: CGFloat(n) / box.height))
            context.render(crop, toBitmap: &px, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
            // least squares L = a + b·x + c·y over skin-coloured pixels inside the face oval
            var sums = [Double](repeating: 0, count: 9), cnt = 0.0
            var A = [[Double]](repeating: [0, 0, 0], count: 3), B = [0.0, 0.0, 0.0]
            for y in 0..<n { for x in 0..<n {
                let i = (y * n + x) * 4, r = px[i], g = px[i + 1], b = px[i + 2]
                let u = (Double(x) + 0.5) / Double(n) * 2 - 1, v = (Double(y) + 0.5) / Double(n) * 2 - 1
                guard u * u / 0.7 + v * v / 0.9 < 1, r > g, g > b, r - b > 0.06, r < 0.98 else { continue }
                let L = Double(0.299 * r + 0.587 * g + 0.114 * b)
                let row = [1, u, v]
                for a in 0..<3 { for c in 0..<3 { A[a][c] += row[a] * row[c] }; B[a] += row[a] * L }
                cnt += 1
            } }
            _ = sums
            guard cnt > 200, let sol = solve3(A, B), sol[0] > 0.05 else { continue }
            let (a0, bx, cy) = (sol[0], sol[1], sol[2])
            guard abs(bx) + abs(cy) > 0.02 * a0 else { continue }          // already even
            // ratio = a0 / (a0 + k·(bx·u + cy·v)), over the face (u, v: -1…1 across the box), fading out beyond it
            let k = Double(amount)
            let ramp = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: box.midX - box.width / 2 * CGFloat(bx), y: box.midY - box.height / 2 * CGFloat(cy)),
                "inputPoint1": CIVector(x: box.midX + box.width / 2 * CGFloat(bx), y: box.midY + box.height / 2 * CGFloat(cy)),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
            let span = (bx * bx + cy * cy).squareRoot()                     // the ramp goes 0 → 1 over ±span
            let lo = max(0.72, a0 / (a0 + k * span)), hi = min(1.45, a0 / max(a0 - k * span, 1e-3))
            let fade = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: box.midX, y: box.midY), "inputRadius0": 0.35 * max(box.width, box.height),
                "inputRadius1": 0.75 * max(box.width, box.height),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)])!.outputImage!
            out = Self.relight.apply(extent: e, arguments: [out, ramp.cropped(to: e), fade.cropped(to: e), Float(hi), Float(lo)])!
        }
        return out
    }

    // gain = mix(1, mix(hi, lo, ramp), fade): the dark side (ramp 0) lifted, the bright side (ramp 1) brought down
    private static let relight = CIColorKernel(source: """
        kernel vec4 r(__sample c, __sample ramp, __sample fade, float hi, float lo) {
          // skin only (warm: r > g > b): hair, background and clothes keep their light (a halo otherwise)
          float skin = smoothstep(0.0, 0.04, c.r - c.g) * smoothstep(0.0, 0.03, c.g - c.b) * smoothstep(0.08, 0.2, c.r);
          float g = mix(1.0, mix(hi, lo, ramp.r), fade.r * skin);
          return vec4(clamp(c.rgb * g, 0.0, 1.0), c.a);
        }
        """)!

    private static func solve3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var m = A, v = b
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-9 else { return nil }
            m.swapAt(c, p); v.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = m[r][c] / m[c][c]
                for k in 0..<3 { m[r][k] -= f * m[c][k] }; v[r] -= f * v[c]
            }
        }
        return (0..<3).map { v[$0] / m[$0][$0] }
    }
}
