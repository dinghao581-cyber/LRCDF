import AppKit

/// An immediate, approximate picture of a tweak (暗/亮, 冷/暖, 淡/浓), shown until Lightroom's own render arrives:
/// that one takes about ten seconds, this one a few hundredths. Gains in linear light, saturation around the
/// luminance, contrast around mid-grey; the numbers were fitted to Lightroom's renders of the twelve single tweaks
/// (they explain about three quarters of the change in brightness and half of the change in colour).
enum Quick {
    private static var made: [String: NSImage] = [:]
    private static var order: [String] = []

    static func picture(_ source: NSImage, key: String, tweak: Tweak, own: (shadow: CGPoint, high: CGPoint) = (.zero, .zero)) -> NSImage {
        let name = "\(key)|\(tweak.key)"
        if let ready = made[name] { return ready }
        let result = apply(source, tweak, own) ?? source
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

    // Split toning as Lightroom renders it is close to three separate curves, one per channel: how far a channel
    // moves depends on that channel's own value, not on the pixel's brightness (found by GPT's survey of
    // 2026-11-16 and confirmed on our own renders). Each curve = a shape over the channel's sRGB value (25 points,
    // 0 … 1, straight lines between) times a factor for the channel: a 3 x 3 table times the pure colour of the
    // hue, times amount / 100. Fitted to 16 Lightroom renders of one photo; on another look of that photo it
    // explains 66-78 % of the change (the brightness-weighted version before it: 34-69 %).
    private static let shadowShape: [Float] = [0.673, 0.775, 0.908, 0.999, 0.983, 1.0, 0.972, 0.898, 0.793, 0.694, 0.59, 0.501, 0.426,
                                               0.365, 0.315, 0.275, 0.24, 0.204, 0.17, 0.135, 0.104, 0.076, 0.051, 0.025, 0.01]
    private static let highShape: [Float] = [0.01, 0.011, 0.014, 0.022, 0.03, 0.051, 0.081, 0.111, 0.139, 0.177, 0.221, 0.258, 0.306,
                                             0.377, 0.457, 0.551, 0.649, 0.759, 0.856, 0.953, 1.0, 0.972, 0.867, 0.611, 0.403]
    private static let shadowTable: [[Float]] = [[0.1148, -0.1184, -0.0127], [-0.0529, 0.049, -0.0017], [-0.029, -0.0831, 0.0996]]
    private static let highTable: [[Float]] = [[0.106, -0.1039, -0.0093], [-0.0554, 0.0542, -0.0008], [-0.0278, -0.0866, 0.1183]]
    /// Tint, per unit, on linear sRGB: out = in + tint x (this table x in). A compromise between two looks of one
    /// photo: what tint does depends on the look (55-58 % of the change explained on one, 14-26 % on the other).
    private static let tintTable: [[Float]] = [[0.0569, -0.0633, 0.0079], [-0.0236, 0.0646, -0.0435], [-0.0019, 0.0684, -0.0492]]

    /// The factor of each channel's curve for a shadows / highlights point.
    private static func factors(_ point: CGPoint, _ table: [[Float]]) -> [Float] {
        let g = Tweak.grade(point)
        guard g.amount > 0 else { return [0, 0, 0] }
        let c = NSColor(hue: CGFloat(g.hue) / 360, saturation: 1, brightness: 1, alpha: 1)
        let rgb = [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
        return table.map { ($0[0] * rgb[0] + $0[1] * rgb[1] + $0[2] * rgb[2]) * Float(g.amount) / 100 }
    }
    /// A wheel that was set replaces what the look has there: the difference between the two is laid on.
    private static func wash(_ point: CGPoint, instead own: CGPoint, _ table: [[Float]]) -> [Float]? {
        let (new, old) = (factors(point, table), factors(own, table))
        let change = [new[0] - old[0], new[1] - old[1], new[2] - old[2]]
        return change == [0, 0, 0] ? nil : change
    }
    private static func shape(_ table: [Float], _ value: Float) -> Float {
        let at = min(max(value, 0), 1) * 24, i = min(Int(at), 23)
        return table[i] + (table[i + 1] - table[i]) * (at - Float(i))
    }

    private static func apply(_ image: NSImage, _ t: Tweak, _ own: (shadow: CGPoint, high: CGPoint)) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (w, h) = (cg.width, cg.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }
        let (b, warm, rich) = (Float(t.bright), Float(t.warm), Float(t.rich))
        let tint = Float(t.tint)
        let gr = powf(2, 0.162 * b + 0.070 * warm - 0.012 * rich)
        let gg = powf(2, 0.158 * b + 0.026 * warm - 0.012 * rich)
        let gb = powf(2, 0.150 * b - 0.025 * warm - 0.013 * rich)
        let shadow = t.shadow.flatMap { wash($0, instead: own.shadow, shadowTable) }, high = t.high.flatMap { wash($0, instead: own.high, highTable) }
        let m = tintTable.map { $0.map { $0 * tint } }
        let saturation = 1 + 0.095 * rich
        let contrast = 1 - 0.055 * b + 0.016 * rich
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        toLinear.withUnsafeBufferPointer { lin in
            toSRGB.withUnsafeBufferPointer { enc in
                for i in stride(from: 0, to: w * h * 4, by: 4) {
                    var r = lin[Int(pixels[i])] * gr, g = lin[Int(pixels[i + 1])] * gg, bl = lin[Int(pixels[i + 2])] * gb
                    if tint != 0 {       // tint moves the channels into one another: a table, not three gains
                        let (r0, g0, b0) = (r, g, bl)
                        r += m[0][0] * r0 + m[0][1] * g0 + m[0][2] * b0
                        g += m[1][0] * r0 + m[1][1] * g0 + m[1][2] * b0
                        bl += m[2][0] * r0 + m[2][1] * g0 + m[2][2] * b0
                    }
                    let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
                    r = y + saturation * (r - y); g = y + saturation * (g - y); bl = y + saturation * (bl - y)
                    var values = [r, g, bl]
                    for c in 0..<3 { values[c] = 0.5 + contrast * (enc[Int(min(max(values[c], 0), 1) * 4096)] - 0.5) }
                    if let shadow { for c in 0..<3 { values[c] += shape(shadowShape, values[c]) * shadow[c] } }
                    if let high { for c in 0..<3 { values[c] += shape(highShape, values[c]) * high[c] } }
                    for c in 0..<3 { pixels[i + c] = UInt8(min(max(values[c] * 255 + 0.5, 0), 255)) }
                }
            }
        }
        guard let out = context.makeImage() else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}
