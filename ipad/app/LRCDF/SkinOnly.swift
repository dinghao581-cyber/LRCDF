import CoreImage
import Foundation

/// 橙黄只落皮肤 - the look's skin corrections touch the skin only (the Mac since 369e560, CLAUDE.md "The look's skin
/// corrections touch the skin only"; docs/colorchart/REPORT.md). Each look lowers the saturation of orange and yellow and
/// lifts their lightness for the sake of skin; wood, warm clothes and warm light were thinned and lifted with it.
/// The iPad has no orange / yellow slider: that treatment is inside each photo's predicted colour table (and inside the
/// extra tables of the looks built on look a). So:
///  1. `flatten`: a second table without it. In the orange / yellow hue band (HSV hue 345°…110°, full strength 5°…90°) a
///     cell's change of luminance and chroma (as log ratios) is replaced by the change the same table makes at the
///     band's two edges, at the same HSV saturation and value, interpolated along the hue; the hue the table gives is
///     kept (the Mac zeroes saturation and luminance only). Measured on the 80 test tables: the orange dip (chroma
///     -16 %, luminance +17 % against the neighbouring hues) is gone, everything outside the band is untouched.
///  2. `mask`: where the skin is, as on the Mac (lrcdf/skinmask.py): the selfie segmenter's body + face skin on the whole
///     picture > 0.5 AND a skin colour (blemish.skin_like > 0.25 on a blurred copy), on a 512 px copy, edges softened;
///     skin under 0.4 % of the picture: no mask, the look stays as the model gives it.
///  3. Render: original table on the skin, the flattened one elsewhere, blended by the mask (Engine.render).
/// On by default (user, 2026-11-16, after the comparison sheets: "现在就打开"; TESTHOOKS: LRCDF_SKINONLY=0 turns it off).
/// Anything that fails or takes too long falls back to the look as made (the original table on the whole picture).
enum SkinOnly {
    #if TESTHOOKS
    nonisolated(unsafe) static var on = ProcessInfo.processInfo.environment["LRCDF_SKINONLY"] != "0"
    #else
    static let on = true
    #endif
    static let MASK_BUDGET: TimeInterval = 3      // seconds: a slower mask is not used

    static let HA: Float = 345, HB: Float = 110, IN0: Float = 5, IN1: Float = 90
    static let AREA_MIN: Float = 0.004, WORK: CGFloat = 512

    private static func sst(_ x: Float, _ a: Float, _ b: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
    private static func unwrap(_ h: Float) -> Float { h >= HA ? h - 360 : h }
    /// 0…1: how much of a cell's own orange / yellow treatment is taken out.
    private static func window(_ h: Float) -> Float {
        let u = unwrap(h), a = HA - 360
        guard u > a, u < HB else { return 0 }
        return u < IN0 ? sst(u, a, IN0) : 1 - sst(u, IN1, HB)
    }
    private static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let v = max(c.x, c.y, c.z), m = min(c.x, c.y, c.z), d = v - m
        guard d > 1e-6, v > 0 else { return (0, 0, v) }
        var h: Float
        if v == c.x { h = 60 * (c.y - c.z) / d } else if v == c.y { h = 120 + 60 * (c.z - c.x) / d } else { h = 240 + 60 * (c.x - c.y) / d }
        if h < 0 { h += 360 }
        return (h, d / v, v)
    }
    private static func rgb(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh) % 6, f = hh - Float(Int(hh))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i { case 0: return [v, t, p]; case 1: return [q, v, p]; case 2: return [p, v, t]; case 3: return [p, q, v]; case 4: return [t, p, v]; default: return [v, p, q] }
    }
    // sRGB-encoded colour ↔ Lab (D65, OpenCV's numbers, as SkinKeep) and luminance
    private static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> { SkinKeep.lab(SkinKeep.lin(c.x), SkinKeep.lin(c.y), SkinKeep.lin(c.z)) }
    private static func Y(_ c: SIMD3<Float>) -> Float { 0.212671 * SkinKeep.lin(c.x) + 0.715160 * SkinKeep.lin(c.y) + 0.072169 * SkinKeep.lin(c.z) }
    private static func unlab(_ L: Float, _ a: Float, _ b: Float) -> SIMD3<Float> {
        func fi(_ t: Float) -> Float { t > 0.206893 ? t * t * t : (t - 16 / 116) / 7.787 }
        let fy = (L + 16) / 116
        let X = fi(fy + a / 500) * 0.950456, Yv = L > 7.9996 ? fy * fy * fy : L / 903.3, Z = fi(fy - b / 200) * 1.088754
        let r = 3.240479 * X - 1.53715 * Yv - 0.498535 * Z, g = -0.969256 * X + 1.875991 * Yv + 0.041556 * Z, bb = 0.055648 * X - 0.204043 * Yv + 1.057311 * Z
        return SIMD3(SkinKeep.enc(r), SkinKeep.enc(g), SkinKeep.enc(bb)).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// The table without its own orange / yellow treatment. `cube`: RGBA float, red fastest, `n`³ cells, on sRGB numbers.
    static func flatten(_ cube: [Float], _ n: Int) -> [Float]? {
        guard cube.count == n * n * n * 4 else { return nil }
        let step = 1 / Float(n - 1)
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { let i = ((b * n + g) * n + r) * 4; return SIMD3(cube[i], cube[i + 1], cube[i + 2]) }
        func look(_ x: SIMD3<Float>) -> SIMD3<Float> {          // trilinear, as Core Image
            let p = x.clamped(lowerBound: .zero, upperBound: .one) * Float(n - 1)
            let i0 = SIMD3<Int>(min(Int(p.x), n - 2), min(Int(p.y), n - 2), min(Int(p.z), n - 2))
            let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            var o = SIMD3<Float>(0, 0, 0)
            for dr in 0...1 { for dg in 0...1 { for db in 0...1 {
                let w = (dr == 1 ? f.x : 1 - f.x) * (dg == 1 ? f.y : 1 - f.y) * (db == 1 ? f.z : 1 - f.z)
                o += w * at(i0.x + dr, i0.y + dg, i0.z + db)
            } } }
            return o
        }
        /// the table's change at an input: log luminance ratio, log chroma ratio
        func change(_ x: SIMD3<Float>, _ o: SIMD3<Float>) -> (Float, Float) {
            let li = lab(x), lo = lab(o)
            return (logf(max(Y(o), 1e-5) / max(Y(x), 1e-5)), logf(max(hypotf(lo.y, lo.z), 0.5) / max(hypotf(li.y, li.z), 0.5)))
        }
        var out = cube
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let x = SIMD3<Float>(Float(r), Float(g), Float(b)) * step
            let (h, s, v) = hsv(x)
            let li = lab(x)
            let w = window(h) * sst(hypotf(li.y, li.z), 2, 8)
            guard w > 1e-4 else { continue }
            let o = at(r, g, b)
            let (ay, ac) = change(x, o)
            let xa = rgb(HA, s, v), xb = rgb(HB, s, v)
            let (ya, ca) = change(xa, look(xa)), (yb, cb) = change(xb, look(xb))
            let t = (unwrap(h) - (HA - 360)) / (HB - (HA - 360))
            let by = ya + (yb - ya) * t, bc = ca + (cb - ca) * t
            let lo = lab(o)
            let Yn = min(1, Y(o) * expf(w * (by - ay))), Cn = hypotf(lo.y, lo.z) * expf(w * (bc - ac)), hh = atan2f(lo.z, lo.y)
            let Ln = Yn > 0.008856 ? 116 * cbrtf(Yn) - 16 : 903.3 * Yn
            let c = unlab(Ln, Cn * cosf(hh), Cn * sinf(hh))
            let i = ((b * n + g) * n + r) * 4
            out[i] = c.x; out[i + 1] = c.y; out[i + 2] = c.z
        } } }
        return out.allSatisfy { $0.isFinite } ? out : nil      // never a broken table: nil = the original is used
    }
    static func flatten(_ data: Data, _ n: Int) -> Data? {
        let a = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return flatten(a, n)?.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Where the skin is, 0…1, as an image over the unit square (scaled to any render by `Mask.over`); nil: too little skin.
    static func mask(_ neutral: CIImage, context: CIContext) -> Mask? {
        let start = Date()
        let e = neutral.extent
        let s = min(1, WORK / max(e.width, e.height))
        let w = max(1, Int((e.width * s).rounded())), h = max(1, Int((e.height * s).rounded()))
        let enc = neutral.applyingFilter("CILinearToSRGBToneCurve")
        guard let seg = Beauty.shared.wholeSkin(enc) else { return nil }        // 256 × 256 over the picture, top row first
        // skin colour on a blurred small copy (skinmask.strokes: GaussianBlur sigma 2 on the 512 copy)
        let small = enc.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var m = [Float](repeating: 0, count: w * h)
        var count = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4          // bitmap: top row first
            let sv = seg[min(255, y * 256 / h) * 256 + min(255, x * 256 / w)]
            guard sv > 0.5 else { continue }
            // blemish.skin_like: YCrCb (OpenCV, float) limits widened for every skin-tone group
            let R = px[i], G = px[i + 1], B = px[i + 2]
            let Yl = 0.299 * R + 0.587 * G + 0.114 * B
            let cr = ((R - Yl) * 0.713 + 0.5) * 255, cb = ((B - Yl) * 0.564 + 0.5) * 255
            func cl(_ v: Float) -> Float { min(1, max(0, v)) }
            let like = cl((cr - 128) / 8) * cl((185 - cr) / 8) * cl((cb - 70) / 8) * cl((134 - cb) / 8) * cl((Yl - 0.06) / 0.1)
            if like > 0.25 { m[y * w + x] = 1; count += 1 }
        } }
        // the colour test judges whole regions, not pixels: a region the segmenter calls skin is kept whole when at least
        // 30 % of it has a skin colour (a grey panel taken for skin goes; a forehead under red stage light that failed
        // the colour test stays, ffhq_5brown_00912 - per pixel it showed as a patch of the other table). The Mac tests
        // per pixel (skinmask.strokes); its brush circles hide small holes.
        var segm = [Bool](repeating: false, count: w * h)
        for k in 0..<(w * h) { segm[k] = seg[min(255, (k / w) * 256 / h) * 256 + min(255, (k % w) * 256 / w)] > 0.5 }
        var seen = [Bool](repeating: false, count: w * h), stack: [Int] = [], members: [Int] = []
        stack.reserveCapacity(w * h); members.reserveCapacity(w * h)
        for k0 in 0..<(w * h) where !seen[k0] && segm[k0] {
            members.removeAll(keepingCapacity: true)
            var liked = 0
            stack.append(k0); seen[k0] = true
            while let k = stack.popLast() {
                members.append(k); if m[k] > 0 { liked += 1 }
                let x = k % w
                if x > 0, !seen[k - 1], segm[k - 1] { seen[k - 1] = true; stack.append(k - 1) }
                if x < w - 1, !seen[k + 1], segm[k + 1] { seen[k + 1] = true; stack.append(k + 1) }
                if k >= w, !seen[k - w], segm[k - w] { seen[k - w] = true; stack.append(k - w) }
                if k + w < w * h, !seen[k + w], segm[k + w] { seen[k + w] = true; stack.append(k + w) }
            }
            if Float(liked) >= 0.3 * Float(members.count) { for k in members where m[k] == 0 { m[k] = 1; count += 1 } }
        }
        guard Float(count) / Float(w * h) >= AREA_MIN, -start.timeIntervalSinceNow < MASK_BUDGET else { return nil }
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for k in 0..<(w * h) { rgba[k * 4] = m[k]; rgba[k * 4 + 1] = m[k]; rgba[k * 4 + 2] = m[k] }     // bitmaps: top row first both ways
        let img = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
            .clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))      // soft rim (the brush's feather)
        // kept as numbers: the same mask at any size, no Core Image graph held per photo
        var out = [Float](repeating: 0, count: w * h * 4)
        context.render(img, toBitmap: &out, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        return Mask(pixels: out.withUnsafeBufferPointer { Data(buffer: $0) }, w: w, h: h, share: Float(count) / Float(w * h))
    }

    /// The skin mask of one photo (identity-compared: Tweak stays Hashable).
    final class Mask: Hashable, @unchecked Sendable {
        let pixels: Data; let w: Int, h: Int; let share: Float
        init(pixels: Data, w: Int, h: Int, share: Float) { self.pixels = pixels; self.w = w; self.h = h; self.share = share }
        static func == (a: Mask, b: Mask) -> Bool { a === b }
        func hash(into hs: inout Hasher) { hs.combine(ObjectIdentifier(self)) }
        /// Stretched over `extent` (the photo at any size).
        func over(_ extent: CGRect) -> CIImage {
            CIImage(bitmapData: pixels, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)).concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .cropped(to: extent)
        }
        /// No skin anywhere: the flattened table on the whole picture (tests: the colour chart).
        static let none = Mask(pixels: Data(count: 16), w: 1, h: 1, share: 0)
    }
}
