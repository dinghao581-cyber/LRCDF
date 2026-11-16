import CoreImage
import Foundation

/// 保留本色 - fix R of the skin research (docs/ipad/skin/REPORT.md; the reviewer's ~/LRCDF/ipad/scratch/skin/review/fixr.py,
/// ported number for number). The tone looks pull every skin to one target (L 64, C 15, learned from PPR10K expert a),
/// which whitens dark skin and greys colourful skin. Per photo and look, right after the look:
///  R1  exposure held back by skin depth s (0 light … 1 dark, read on the device from the face by the make-up network's
///      second output; nothing stored): only lift the look itself added is taken back, down to about 2 L above the
///      unedited skin (user 2026-11-16: dark skin "自然深度");
///  R2  skin chroma floor: half of the chroma the look took from skin beyond 3 units is given back (user: "B 保留一半本色"),
///      all of it for dark skin; a chroma gain on hues near the skin's, lightness untouched, never above C 28.
/// No mask at render time: one gain for the whole picture and one hue-keyed colour gain, so no edges.
struct SkinPlan: Hashable {
    var gain: Float = 1          // linear-light exposure factor (≤ 1)
    var chroma: Float = 1        // chroma gain at the skin hue
    var hue: Float = 0           // skin hue (degrees, Lab)
    var isNone: Bool { gain >= 0.999 && chroma <= 1.001 }
}

enum SkinKeep {
    // fixr.P0
    static let L_REF: Float = 62, L_SLOPE: Float = 20, ALLOW: Float = 2, D0: Float = 3, R_BASE: Float = 0.5,
               C_CAP: Float = 28, G_MAX: Float = 1.4, H_IN: Float = 20, H_OUT: Float = 45, S_LO: Float = 0.5, S_HI: Float = 3.5,
               T_LO: Float = 26, T_HI: Float = 40, CAST_LO: Float = 28, CAST_HI: Float = 36

    static func sstep(_ x: Float, _ a: Float, _ b: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

    /// Skin depth 0…1 from the face score (zero-shot "dark skin" vs "light skin"); the largest face of 100 px or more.
    static func depth(_ faces: [Face], width: CGFloat) -> Float {
        guard let f = faces.filter({ $0.width * width >= 100 }).max(by: { $0.width < $1.width }) else { return 0 }
        return sstep(f.depth, S_LO, S_HI)
    }

    // MARK: colour (sRGB D65, as OpenCV's Lab in the reviewer's code)

    static func enc(_ c: Float) -> Float { c <= 0.0031308 ? 12.92 * c : 1.055 * powf(max(c, 0), 1 / 2.4) - 0.055 }
    static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((max(c, 0) + 0.055) / 1.055, 2.4) }
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {        // linear rgb (clipped as an 8-bit encode would)
        let (r, g, b) = (lin(min(1, enc(r))), lin(min(1, enc(g))), lin(min(1, enc(b))))
        let X = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456, Y = 0.212671 * r + 0.715160 * g + 0.072169 * b,
            Z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754
        func f(_ t: Float) -> Float { t > 0.008856 ? powf(t, 1 / 3) : 7.787 * t + 16 / 116 }
        let L = Y > 0.008856 ? 116 * powf(Y, 1 / 3) - 16 : 903.3 * Y
        return SIMD3(L, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }
    /// Mean L, chroma and hue of the mean a/b.
    static func stats(_ px: [SIMD3<Float>], gain: Float = 1) -> (L: Float, C: Float, h: Float) {
        var s = SIMD3<Float>(0, 0, 0)
        for p in px { s += lab(p.x * gain, p.y * gain, p.z * gain) }
        s /= Float(max(px.count, 1))
        return (s.x, hypotf(s.y, s.z), atan2f(s.z, s.y) * 180 / .pi)
    }
    static func gainTo(_ px: [SIMD3<Float>], _ L: Float) -> Float {
        var lo: Float = 0.02, hi: Float = 50
        for _ in 0..<34 { let g = (lo * hi).squareRoot(); if stats(px, gain: g).L < L { lo = g } else { hi = g } }
        return (lo * hi).squareRoot()
    }
    static func hueWeight(_ L: SIMD3<Float>, _ h0: Float) -> Float {
        let h = atan2f(L.z, L.y) * 180 / .pi
        let d = abs((((h - h0 + 180).truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) - 180)
        var w = min(1, max(0, (H_OUT - d) / (H_OUT - H_IN))); w = 0.5 - 0.5 * cosf(.pi * w)
        let C = hypotf(L.y, L.z)
        return w * sstep(C, 2, 8) * (1 - sstep(C, T_LO, T_HI))
    }

    /// fixr.plan: `neutral`, `toned`: the same skin pixels (linear rgb) before and after the look; `s`: skin depth.
    static func plan(neutral: [SIMD3<Float>], toned: [SIMD3<Float>], s: Float) -> SkinPlan {
        guard neutral.count >= 50 else { return SkinPlan() }
        let (L0, C0, _) = stats(neutral), (Lt, _, _) = stats(toned)
        let Lg = Lt - s * max(0, Lt - max(L_REF - L_SLOPE * s, L0 + ALLOW))
        let g: Float = Lg < Lt - 0.05 ? gainTo(toned, Lg) : 1
        let T1 = toned.map { lab($0.x * g, $0.y * g, $0.z * g) }
        var m = SIMD3<Float>(0, 0, 0); for t in T1 { m += t }; m /= Float(T1.count)
        let L1 = m.x, C1 = hypotf(m.y, m.z), h1 = atan2f(m.z, m.y) * 180 / .pi
        let Cref = stats(neutral, gain: gainTo(neutral, L1)).C
        let D = Cref - C1
        let r = R_BASE * (1 - sstep(C0, CAST_LO, CAST_HI)) + (1 - R_BASE) * s     // strongly coloured light on light skin: leave the look's cast removal alone
        let Cg = min(C1 + r * max(0, D - D0 * (1 - s)), max(C_CAP, C1))
        var cg: Float = 1
        if Cg > C1 + 0.05 {
            let w = T1.map { hueWeight($0, h1) }
            cg = Cg / C1
            for _ in 0..<4 {                // the skin mean lands on the goal although the window is < 1 on part of the skin
                var a: Float = 0, b: Float = 0
                for (t, wi) in zip(T1, w) { let k = 1 + (cg - 1) * wi; a += t.y * k; b += t.z * k }
                let c = hypotf(a, b) / Float(T1.count)
                cg = min(G_MAX, 1 + (cg - 1) * (Cg - C1) / max(c - C1, 1e-3))
            }
        }
        return SkinPlan(gain: g, chroma: cg, hue: h1)
    }

    // MARK: render

    private static let chromaKernel = CIColorKernel(source: """
        float lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((max(c, 0.0) + 0.055) / 1.055, 2.4); }
        float ff(float t) { return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0; }
        float enc(float c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055; }
        float fi(float t) { return t > 0.206893 ? t * t * t : (t - 16.0 / 116.0) / 7.787; }
        float sst(float x, float a, float b) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
        kernel vec4 k(__sample s, float cg, float h0) {
          vec3 c = vec3(lin(s.r), lin(s.g), lin(s.b));
          float X = dot(c, vec3(0.412453, 0.357580, 0.180423)) / 0.950456;
          float Y = dot(c, vec3(0.212671, 0.715160, 0.072169));
          float Z = dot(c, vec3(0.019334, 0.119193, 0.950227)) / 1.088754;
          float L = Y > 0.008856 ? 116.0 * pow(Y, 1.0 / 3.0) - 16.0 : 903.3 * Y;
          float A = 500.0 * (ff(X) - ff(Y)), B = 200.0 * (ff(Y) - ff(Z));
          float C = sqrt(A * A + B * B);
          float d = abs(mod(degrees(atan(B, A)) - h0 + 540.0, 360.0) - 180.0);
          float w = clamp((45.0 - d) / 25.0, 0.0, 1.0); w = 0.5 - 0.5 * cos(3.14159265 * w);
          w *= sst(C, 2.0, 8.0) * (1.0 - sst(C, 26.0, 40.0));
          float kk = 1.0 + (cg - 1.0) * w;
          A *= kk; B *= kk;
          float fy = (L + 16.0) / 116.0;
          vec3 xyz = vec3(fi(fy + A / 500.0) * 0.950456, fi(fy), fi(fy - B / 200.0) * 1.088754);
          vec3 o = vec3(dot(xyz, vec3(3.240479, -1.53715, -0.498535)), dot(xyz, vec3(-0.969256, 1.875991, 0.041556)),
                        dot(xyz, vec3(0.055648, -0.204043, 1.057311)));
          return vec4(enc(o.r), enc(o.g), enc(o.b), s.a);
        }
        """)!

    /// The plan applied to a linear picture (any size).
    static func apply(_ img: CIImage, _ p: SkinPlan) -> CIImage {
        guard !p.isNone else { return img }
        var out = img
        if p.gain < 0.999 {
            let g = CGFloat(p.gain)
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)])
        }
        if p.chroma > 1.001 {
            let e = out.extent
            out = chromaKernel.apply(extent: e, arguments: [out.applyingFilter("CILinearToSRGBToneCurve"), p.chroma, p.hue])!
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        return out.cropped(to: img.extent)
    }

    /// Skin pixels of a photo, before and after the look (linear rgb, up to 20 000, same positions): rendered small,
    /// the faces' skin maps (> 0.5) as the mask.
    static func samples(neutral: CIImage, toned: CIImage, faces: [Face], context: CIContext) -> ([SIMD3<Float>], [SIMD3<Float>]) {
        let e = neutral.extent, n = 256
        let s = CGFloat(n) / max(e.width, e.height)
        let w = Int((e.width * s).rounded()), h = Int((e.height * s).rounded())
        func px(_ i: CIImage) -> [Float] {
            var a = [Float](repeating: 0, count: w * h * 4)
            let small = i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: 1, y: 1))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            context.render(small, toBitmap: &a, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return a
        }
        var mask = CIImage(color: .black).cropped(to: e)
        for f in faces {
            guard let sk = f.skin else { continue }
            let a = CGRect(x: f.area.minX * e.width + e.minX, y: f.area.minY * e.height + e.minY, width: f.area.width * e.width, height: f.area.height * e.height)
            let m = sk.transformed(by: CGAffineTransform(scaleX: a.width / 256, y: a.height / 256).concatenating(CGAffineTransform(translationX: a.minX, y: a.minY)))
            mask = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: e)
        }
        let N = px(neutral), T = px(toned), M = px(mask)
        var a: [SIMD3<Float>] = [], b: [SIMD3<Float>] = []
        for i in 0..<(w * h) where M[i * 4] > 0.5 {
            // as the reviewer's mask (common.load): near-black (beard, nostrils, hair in the skin map) and burnt-out pixels
            // are not skin; with them a dark face's mean fell ~6 L and the hold-back stopped at L 42 (+7 L left)
            let L = lab(N[i * 4], N[i * 4 + 1], N[i * 4 + 2]).x
            guard L > 8, L < 97 else { continue }
            a.append(SIMD3(N[i * 4], N[i * 4 + 1], N[i * 4 + 2])); b.append(SIMD3(T[i * 4], T[i * 4 + 1], T[i * 4 + 2]))
        }
        if a.count > 20000 { let k = a.count / 20000 + 1; a = stride(from: 0, to: a.count, by: k).map { a[$0] }; b = stride(from: 0, to: b.count, by: k).map { b[$0] } }
        return (a, b)
    }
}
