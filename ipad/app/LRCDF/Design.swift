import CoreGraphics
import SwiftUI

/// The design language of the Mac app (project/app/Sources/LRCDF/Design.swift, docs/design/DESIGN.md and FOR_IPAD.md),
/// for the iPad. The photograph is the interface: a dark room lit by the photo itself far out of focus, controls of
/// smoked Liquid Glass floating in it, focus yellow for what is chosen, solid white for the one action.
enum DS {
    // colour
    static let ink = Color.white
    static let soft = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.12)
    static let line = Color.white.opacity(0.10)
    static let focus = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let onFocus = Color.black
    static let smoke = Color.black.opacity(0.38)
    static let roomShade = 0.62

    // type
    /// 宋体 bold when it is on the device (Fonts.swift fetches it from Apple once), the system face until then.
    static func display(_ size: CGFloat) -> Font { Fonts.has() ? .custom("STSongti-SC-Bold", size: size) : .system(size: size, weight: .semibold) }
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let note = Font.system(size: 11)

    // measure
    static let touch: CGFloat = 44
    static let gap: CGFloat = 14
    static let pad: CGFloat = 20
    static let panel: CGFloat = 26
    static let tray: CGFloat = 24
    static let chip: CGFloat = 12
    static let photo: CGFloat = 8
    static let side: CGFloat = 320
    static let wide: CGFloat = 1000

    // motion
    static let pick = Animation.snappy(duration: 0.32)
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.74)
}

extension View {
    /// Smoked Liquid Glass (the system's glassEffect, never a home-made blur). `clear` for labels on the photo.
    func glass<S: Shape>(_ shape: S, smoked: Bool = true, interactive: Bool = false, clear: Bool = false) -> some View {
        glassEffect((clear ? Glass.clear : Glass.regular).tint(smoked && !clear ? DS.smoke : nil).interactive(interactive), in: shape)
    }
}

/// The room: black, lit by the photo on screen far out of focus. Glass needs something behind it to be glass.
struct Room: View {
    var image: CGImage?
    private static var small: [ObjectIdentifier: CGImage] = [:]

    /// A few dozen pixels are all a blur this size needs.
    private static func shrunk(_ image: CGImage) -> CGImage? {
        let key = ObjectIdentifier(image)
        if let ready = small[key] { return ready }
        let w = 96, h = max(1, 96 * image.height / max(image.width, 1))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let made = ctx.makeImage()
        if small.count > 16 { small.removeAll() }
        small[key] = made
        return made
    }

    var body: some View {
        Color.black.overlay {
            if let image, let s = Self.shrunk(image) {
                Image(decorative: s, scale: 1).resizable().interpolation(.high).scaledToFill()
                    .blur(radius: 60, opaque: true).saturation(0.6)
                    .overlay(Color.black.opacity(DS.roomShade))
                    .id(ObjectIdentifier(image)).transition(.opacity)
            }
        }
        .clipped()
        .animation(.smooth(duration: 0.6), value: image.map { ObjectIdentifier($0) })
        .ignoresSafeArea()
    }
}

/// Four corners, as a viewfinder marks focus: around the chosen look.
struct Brackets: Shape {
    var arm: CGFloat = 11
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = min(arm, r.width / 3, r.height / 3)
        for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: c.x + a * dx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + a * dy))
        }
        return p
    }
}

struct FocusMark: View {
    var arm: CGFloat = 11
    var body: some View {
        Brackets(arm: arm).stroke(DS.focus, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

struct PressDown: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// The one action of a screen: the only solid thing on it.
struct PrimaryButton: View {
    let title: String
    var wide = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                .lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
                .padding(.horizontal, 26).frame(maxWidth: wide ? .infinity : nil).frame(height: wide ? 52 : DS.touch + 4)
                .background(.white.opacity(enabled ? 1 : 0.35), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(PressDown())
    }
}

/// Everything else you can press: glass.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.ink).lineLimit(1)
            .padding(.horizontal, 18).frame(height: DS.touch)
            .glass(Capsule(), interactive: true)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
