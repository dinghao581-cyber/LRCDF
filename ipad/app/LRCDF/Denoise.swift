import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small, local chroma denoiser. Input and output are extended linear sRGB.
/// There is deliberately no luminance smoothing: pores, hair and fabric keep their
/// luminance signal. This is not a replacement for a learned RAW denoiser.
enum Denoise {
    struct RawSettings {
        let luminance: Float
        let color: Float
        let detail: Float
        let sharpness: Float
        let contrast: Float
    }

    /// Leave Apple's per-camera decoder defaults intact. RAW 9 already performs
    /// learned demosaic / denoise; legacy detail and colour controls are not a
    /// portable way to increase it. Extra chroma filtering did not improve the
    /// tested RAW 9 renders, so the selected RAW path also bypasses apply.
    static func rawSettings(iso: Int?) -> RawSettings? { nil }

    /// Recommendation only. Missing EXIF must not turn the switch on by itself.
    static func isRecommended(iso: Int?, isRAW: Bool = false) -> Bool { !isRAW && (iso ?? 0) >= 1600 }

    /// ImageIO identifies the actual file format, not its filename extension.
    /// This metadata-only check does not decode pixels or request RAW resources.
    static func isRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { return false }
        return UTType(type as String)?.conforms(to: .rawImage) ?? false
    }

    /// Read metadata without decoding image pixels. 65535 is the EXIF overflow
    /// marker, so consult the extended ISO field before accepting that value.
    static func iso(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        func positive(_ value: Any?) -> Int? {
            if let values = value as? [Any] { return values.compactMap { positive($0) }.first }
            guard let number = value as? NSNumber else { return nil }
            let v = number.doubleValue
            guard v.isFinite, v > 0, v <= 100_000_000 else { return nil }
            return Int(v.rounded())
        }
        let legacy = positive(exif[kCGImagePropertyExifISOSpeedRatings as String])
        if let legacy, legacy != 65535 { return legacy }
        for key in [kCGImagePropertyExifISOSpeed, kCGImagePropertyExifRecommendedExposureIndex,
                    kCGImagePropertyExifStandardOutputSensitivity] {
            if let value = positive(exif[key as String]), value != 65535 { return value }
        }
        return nil
    }

    /// Useful to test that the runtime compiled the kernel. Failure is a safe
    /// no-op, never a crash or a black export.
    static var isAvailable: Bool { chromaKernel != nil }

    /// Denoise at the ORIGINAL decoded resolution, before resizing, tone, beauty
    /// and artificial grain. Radius is two source pixels, independent of output
    /// size. Render this graph in Engine.strips; its ROI reads a two-pixel halo.
    ///
    /// RAW input, known ISO below 1600 and strength zero return the original image
    /// exactly. Pass isRAW(url) for the original file; a CIImage has no reliable
    /// provenance once it has been decoded. RAW keeps the decoder's own denoise.
    /// With unknown ISO an explicit call uses a conservative amount; automatic
    /// recommendation remains false. Strength is an overall 0...1 multiplier.
    /// Alpha, extent and extended-range values are retained. Colour microdetail
    /// can still change: only the linear luminance signal is explicitly protected.
    static func apply(_ linear: CIImage, iso: Int?, strength: Float = 1, isRAW: Bool = false) -> CIImage {
        let extent = linear.extent
        guard !isRAW, strength.isFinite, strength > 0,
              extent.width > 0, extent.height > 0,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              iso.map({ $0 >= 1600 }) ?? true,
              let kernel = chromaKernel else { return linear }
        let stops = iso.map { Float(min(3, max(0, log2(Double($0) / 1600)))) } ?? 0
        let amount = min(1, strength) * (iso == nil ? 0.30 : 0.40 + 0.15 * stops)
        let lumaSigma = 0.04 + 0.015 * stops
        let chromaSigma = 0.08 + 0.04 * stops
        let source = linear.clampedToExtent()
        return kernel.apply(extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [source, amount, lumaSigma, chromaSigma])?.cropped(to: extent) ?? linear
    }

    /// Preview/export agreement requires this order. Passing an already reduced
    /// 2400-pixel decode to apply changes which source neighbours are averaged.
    /// Use the same full decode for preview and export, then reduce the result.
    /// No full-size CPU allocation is made here: the returned CI graph is lazy.
    static func preview(_ fullLinear: CIImage, iso: Int?, strength: Float = 1, isRAW: Bool = false,
                        maxSide: CGFloat = 2400) -> CIImage {
        let image = apply(fullLinear, iso: iso, strength: strength, isRAW: isRAW)
        let e = image.extent, side = max(e.width, e.height)
        guard maxSide.isFinite, maxSide > 0, side.isFinite, side > maxSide else { return image }
        let scale = maxSide / side
        let target = e.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        // Clamp the denoised result as well as the input. Otherwise Lanczos can
        // use a different edge extension for a lazy kernel and a bitmap export.
        return image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1]).cropped(to: target)
    }

    // A joint bilateral average of chromaticity (RGB - Y) / Y, reconstructed
    // using the centre pixel's ORIGINAL Y. Averaging additive RGB - Y would
    // turn luminance noise on a saturated constant-colour surface into colour
    // noise. Constant chromaticity is now an exact fixed point even when Y is
    // noisy. Near black (Y <= .002) stays untouched to avoid unstable ratios.
    // The guide uses sqrt(Y) to make its range threshold less exposure-dependent.
    // A second gate preserves colour boundaries of similar luminance. The
    // centre sample always has weight 1. Alpha discontinuities cannot bleed.
    // Unroll the fixed 5x5 footprint: Core Image's kernel compiler need not infer
    // loop bounds, and the sampler's exact finite ROI stays obvious.
    private static let chromaKernel: CIKernel? = {
        var taps = ""
        for y in -2...2 { for x in -2...2 {
            let spatial = exp(-Double(x * x + y * y) / (2 * 1.4 * 1.4))
            taps += """
                {
                    vec4 q = unpremultiply(sample(src, samplerTransform(src, p + vec2(\(x).0, \(y).0))));
                    float qy = dot(q.rgb, weights);
                    vec3 qc = (q.rgb - vec3(qy)) / max(qy, 0.002);
                    float dy = (sqrt(max(qy, 0.0)) - rootY) / lumaSigma;
                    vec3 dc = (qc - normalC) * sqrt(max(0.5 * (qy + y), 0.002)) / chromaSigma;
                    float w = \(spatial) * exp(-0.5 * (dy * dy + dot(dc, dc)))
                        * max(0.0, 1.0 - abs(q.a - c.a) * 20.0) * step(0.002, qy);
                    sum += qc * w;
                    total += w;
                }

                """
        } }
        return CIKernel(source: """
            kernel vec4 chroma(sampler src, float amount, float lumaSigma, float chromaSigma) {
                vec2 p = destCoord();
                vec4 c = unpremultiply(sample(src, samplerTransform(src, p)));
                vec3 weights = vec3(0.2126, 0.7152, 0.0722);
                float y = dot(c.rgb, weights);
                if (y <= 0.002) { return premultiply(c); }
                float rootY = sqrt(max(y, 0.0));
                vec3 colour = c.rgb - vec3(y);
                vec3 normalC = colour / y;
                vec3 sum = vec3(0.0);
                float total = 0.0;
                \(taps)
                vec3 delta = amount * (y * sum / max(total, 0.000001) - colour);
                delta -= vec3(dot(delta, weights));
                return premultiply(vec4(c.rgb + delta, c.a));
            }
            """)
    }()
}
