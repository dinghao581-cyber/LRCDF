import AppKit

/// An immediate, approximate picture of a tweak (暗/亮, 冷/暖, 淡/浓), shown until Lightroom's own render arrives:
/// that one takes about ten seconds, this one a few hundredths. Gains in linear light, saturation around the
/// luminance, contrast around mid-grey; the numbers were fitted to Lightroom's renders of the twelve single tweaks
/// (they explain about three quarters of the change in brightness and half of the change in colour).
enum Quick {
    private static var made: [String: NSImage] = [:]
    private static var order: [String] = []

    static func picture(_ source: NSImage, key: String, tweak: Tweak) -> NSImage {
        let name = "\(key)|\(tweak.argument)"
        if let ready = made[name] { return ready }
        let result = apply(source, tweak) ?? source
        made[name] = result; order.append(name)
        if order.count > 8 { made[order.removeFirst()] = nil }
        return result
    }

    static func forget() { made = [:]; order = [] }

    private static let toLinear: [Float] = (0..<256).map { i in
        let s = Float(i) / 255
        return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
    }
    private static let toSRGB: [Float] = (0...4096).map { i in
        let l = Float(i) / 4096
        return l <= 0.0031308 ? 12.92 * l : 1.055 * powf(l, 1 / 2.4) - 0.055
    }

    private static func apply(_ image: NSImage, _ t: Tweak) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (w, h) = (cg.width, cg.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }
        let (b, warm, rich) = (Float(t.bright), Float(t.warm), Float(t.rich))
        let gr = powf(2, 0.162 * b + 0.070 * warm - 0.012 * rich)
        let gg = powf(2, 0.158 * b + 0.026 * warm - 0.012 * rich)
        let gb = powf(2, 0.150 * b - 0.025 * warm - 0.013 * rich)
        let saturation = 1 + 0.095 * rich
        let contrast = 1 - 0.055 * b + 0.016 * rich
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        toLinear.withUnsafeBufferPointer { lin in
            toSRGB.withUnsafeBufferPointer { enc in
                for i in stride(from: 0, to: w * h * 4, by: 4) {
                    var r = lin[Int(pixels[i])] * gr, g = lin[Int(pixels[i + 1])] * gg, bl = lin[Int(pixels[i + 2])] * gb
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
                    r = y + saturation * (r - y); g = y + saturation * (g - y); bl = y + saturation * (bl - y)
                    let values = [r, g, bl]
                    for c in 0..<3 {
                        let s = enc[Int(min(max(values[c], 0), 1) * 4096)]
                        pixels[i + c] = UInt8(min(max((0.5 + contrast * (s - 0.5)) * 255 + 0.5, 0), 255))
                    }
                }
            }
        }
        guard let out = context.makeImage() else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}
