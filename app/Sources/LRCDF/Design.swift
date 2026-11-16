import SwiftUI

/// The design language, as code. The written version (for the iPad and Windows apps too) is docs/design/DESIGN.md;
/// change the two together.
///
/// In one breath: the photograph is the interface. The window is a dark room lit by the photo itself, far out of
/// focus; controls are smoked glass floating in it. The chrome has no colour of its own. Focus yellow marks what is
/// chosen (the way a viewfinder marks what is in focus), solid white is the one action, and nothing else is coloured.
enum DS {
    // colour
    static let ink = Color.white
    static let soft = Color.white.opacity(0.58)           // secondary text
    static let faint = Color.white.opacity(0.12)          // fills of quiet controls, tracks
    static let line = Color.white.opacity(0.10)           // hairlines
    static let focus = Color(red: 1.0, green: 0.84, blue: 0.04)      // what is chosen; needs attention
    static let onFocus = Color.black
    static let smoke = Color.black.opacity(0.38)          // tint of glass panels: darker than the room, never lighter
    static let roomShade = 0.62                           // black laid over the blurred photo
    static let veil = Color.black.opacity(0.5)            // behind a dialog

    // type: one serif for the few words that name things, the system face for everything else
    static func display(_ size: CGFloat) -> Font { .custom("Songti SC", size: size).weight(.bold) }
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let note = Font.system(size: 11)

    // measure
    static let touch: CGFloat = 44                        // nothing you can press is smaller
    static let gap: CGFloat = 14                          // glass to window edge, glass to glass
    static let pad: CGFloat = 20                          // inside a panel
    static let panel: CGFloat = 26                        // corner radii
    static let tray: CGFloat = 24
    static let chip: CGFloat = 12
    static let thumb: CGFloat = 9
    static let photo: CGFloat = 8
    static let side: CGFloat = 300                        // the inspector
    static let wide: CGFloat = 1000                       // from this width the inspector layout, below it the paged bar

    // motion: springs throughout; a thing that moves says where it came from
    static let pick = Animation.snappy(duration: 0.32)                          // a choice moves its marker
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.74) // the divider coming to rest
    static let zoom = Animation.spring(duration: 0.45, bounce: 0.15)
    static let stage = Animation.spring(duration: 0.55, bounce: 0.12)           // chrome leaving and returning
    static let wipe = 0.42, iris = 0.6                                           // a new picture coming in
}

extension DS {
    /// macOS 26 has Liquid Glass; macOS 14 and 15 get plain dark panels instead (user, 2026-11-17: one package for
    /// all; on older systems "把毛玻璃删掉，其他不改"). Debug builds can force the older look with LRCDF_OLDLOOK=1, to see it here.
    #if DEBUG
    static let forceOldLook = ProcessInfo.processInfo.environment["LRCDF_OLDLOOK"] == "1"
    #else
    static let forceOldLook = false
    #endif
    static var liquidGlass: Bool {
        if forceOldLook { return false }
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// Smoked Liquid Glass. `clear` for small labels that sit on the photo itself.
    /// Before macOS 26: no glass and no blur at all - the same shape filled with the room's shade and the smoke over it
    /// (about 76 % black, darker than the room as the glass is), with a hairline where the glass has its edge.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, smoked: Bool = true, interactive: Bool = false, clear: Bool = false) -> some View {
        if #available(macOS 26, *), !DS.forceOldLook {
            glassEffect((clear ? Glass.clear : Glass.regular).tint(smoked && !clear ? DS.smoke : nil).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    // unsmoked glass (the divider's handle) and clear glass let more of the picture through
                    shape.fill(Color.black.opacity(smoked && !clear ? DS.roomShade : 0))
                    shape.fill(DS.smoke)
                    shape.stroke(DS.line, lineWidth: 1)
                }
            }
        }
    }

    /// Glass shapes that move between places as one (glassEffectID); before macOS 26 they simply move.
    @ViewBuilder
    func glassID(_ id: String, in space: Namespace.ID) -> some View {
        if #available(macOS 26, *), !DS.forceOldLook { glassEffectID(id, in: space) } else { self }
    }
}

/// Glass panels close together that melt into each other (GlassEffectContainer); before macOS 26 a plain group.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 26, *), !DS.forceOldLook { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

/// Four corners, as a viewfinder marks focus: around the chosen look, and on a face being jumped to.
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

extension Shape where Self == Brackets {
    static var brackets: Brackets { Brackets() }
}

struct FocusMark: View {
    var arm: CGFloat = 11
    var body: some View {
        Brackets(arm: arm).stroke(DS.focus, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Buttons

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
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .padding(.horizontal, 24).frame(maxWidth: wide ? .infinity : nil).frame(height: wide ? 48 : DS.touch)
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
    }
}

/// A symbol to press, with a full-size target around it.
struct IconButton: View {
    let symbol: String
    var label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .frame(width: DS.touch, height: DS.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// A floating panel for the things that interrupt: prompts, the first-run installer, the rights card.
struct DialogPanel<Content: View>: View {
    var width: CGFloat = 480
    var spacing: CGFloat = 16
    var alignment: HorizontalAlignment = .center
    @ViewBuilder var content: () -> Content
    @State private var arrived = false

    var body: some View {
        ZStack {
            DS.veil.ignoresSafeArea()
            VStack(alignment: alignment, spacing: spacing) { content() }
                .padding(30).frame(width: width)
                .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
                .scaleEffect(arrived ? 1 : 0.94)        // the panel steps forward; the veil only fades
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(.spring(duration: 0.45, bounce: 0.2)) { arrived = true } }
    }
}

// MARK: - Controls

/// 暗 ───●─── 亮 +37: a stepless row with its number. Drag anywhere on the track: the knob moves from where it
/// stands, it does not jump to the pointer (the middle catches); the words
/// at the ends go five at a time and repeat while held; a double click on the track, or a click on the number,
/// goes back to 0. The value runs from -2 to 2 and is shown as -100 … +100. A row of a `Grid` (see `Tweaks`).
struct ToneRow: View {
    let low: String, high: String
    @Binding var value: Double
    var dragging: (Bool) -> Void = { _ in }       // told when a drag starts and when it ends
    @State private var start: Int?
    private var units: Int { Int((value * 50).rounded()) }
    private func set(_ next: Int) {
        let clamped = min(100, max(-100, next))
        if clamped != units { value = Double(clamped) / 50 }
    }

    var body: some View {
        GridRow {
            end(low, -5)
            GeometryReader { box in
                let knob: CGFloat = 16, width = box.size.width
                let at = CGFloat(units + 100) / 200 * (width - knob)
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.faint).frame(height: 2).padding(.horizontal, knob / 2)
                    Circle().fill(DS.soft).frame(width: 5, height: 5).offset(x: width / 2 - 2.5)
                    Capsule().fill(DS.focus.opacity(0.8)).frame(width: abs(at + knob / 2 - width / 2), height: 2)
                        .offset(x: min(at + knob / 2, width / 2))
                    Circle().fill(units == 0 ? DS.ink : DS.focus).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3).offset(x: at)
                }
                .frame(height: DS.touch).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in      // from where it stands, wherever the press lands
                    let from = start ?? units
                    if start == nil { dragging(true) }
                    start = from
                    let next = from + Int((drag.translation.width / max(width - knob, 1) * 200).rounded())
                    set(abs(next) < 4 ? 0 : next)                  // the middle catches
                }.onEnded { _ in start = nil; dragging(false) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(DS.pick) { set(0) } })
            }
            .frame(minWidth: 90).frame(height: DS.touch)
            end(high, 5)
            Button { withAnimation(DS.pick) { set(0) } } label: {
                Text(units == 0 ? "0" : units.formatted(.number.sign(strategy: .always())))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(units == 0 ? DS.soft : DS.focus)
                    .frame(minWidth: 38, minHeight: DS.touch, alignment: .trailing).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(low) / \(high)").accessibilityValue(units.formatted())
        .accessibilityAdjustableAction { direction in set(units + (direction == .increment ? 5 : -5)) }
    }

    private func end(_ title: String, _ step: Int) -> some View {
        Button { withAnimation(DS.pick) { set(units + step) } } label: {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.ink)
                .lineLimit(1).fixedSize()        // one character in Chinese, a word elsewhere: the column takes the widest
                .padding(.horizontal, 6).frame(minWidth: DS.touch, minHeight: DS.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
    }
}

/// A round colour wheel: the knob is dragged towards a colour, the centre is "as the look made it". The knob moves
/// from where it stands (it does not jump to the pointer), stays inside the circle, and is caught by the centre;
/// a double click goes back to the centre. `point` lies in the unit circle, x to the right, y upwards.
struct ColourWheel: View {
    enum Kind { case balance, grade }
    let kind: Kind
    @Binding var point: CGPoint
    var home = CGPoint.zero                           // where a double click goes back to: what the look itself has
    var size: CGFloat = 150
    var words: (left: String, right: String, top: String, bottom: String)? = nil
    var name = "", value = ""                         // for VoiceOver
    var dragging: (Bool) -> Void = { _ in }
    @State private var start: CGPoint?

    private var moved: Bool { point != home }
    private func set(_ p: CGPoint) {
        var (x, y) = (p.x, p.y)
        let length = hypot(x, y)
        if length > 1 { x /= length; y /= length }
        if length < 0.04 { x = 0; y = 0 }
        let next = CGPoint(x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100)
        if next != point { point = next }
    }

    /// Clockwise from three o'clock, as AngularGradient runs.
    private var colours: [Color] {
        switch kind {
        case .balance:
            let warm = Color(red: 1, green: 0.67, blue: 0.35), green = Color(red: 0.35, green: 0.82, blue: 0.47)
            let cool = Color(red: 0.35, green: 0.59, blue: 1), pink = Color(red: 1, green: 0.43, blue: 0.75)
            return [warm, green, cool, pink, warm]
        case .grade:
            return (0...12).map { Color(hue: (1 - Double($0) / 12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.9) }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let words { word(words.left) }
            VStack(spacing: 2) {
                if let words { word(words.top) }
                disc
                if let words { word(words.bottom) }
            }
            if let words { word(words.right) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityValue(value)
    }

    private func word(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.ink).lineLimit(1).fixedSize().frame(minWidth: 18)
    }

    private var disc: some View {
        let reach = size / 2 - 9, middle = size / 2
        let knob = CGPoint(x: middle + point.x * reach, y: middle - point.y * reach)
        return ZStack {
            Circle().fill(AngularGradient(colors: colours, center: .center))
            Circle().fill(RadialGradient(colors: [Color(white: 0.46), Color(white: 0.46).opacity(0)], center: .center, startRadius: 0, endRadius: middle))
            Circle().fill(Color(white: 0.25).opacity(0.3))            // never pure colours next to the photo
            Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: size - 12, height: 1)
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: size - 12)
            Circle().fill(DS.soft).frame(width: 5, height: 5)
            if point != .zero {
                Path { p in p.move(to: CGPoint(x: middle, y: middle)); p.addLine(to: knob) }.stroke(moved ? DS.focus : DS.soft, lineWidth: 2)
            }
            Circle().fill(moved ? DS.focus : DS.ink).frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.4), radius: 3).position(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle().inset(by: -12))
        .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
            let from = start ?? point
            if start == nil { dragging(true) }
            start = from
            set(CGPoint(x: from.x + drag.translation.width / reach, y: from.y - drag.translation.height / reach))
        }.onEnded { _ in start = nil; dragging(false) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(DS.pick) { point = home } })
    }
}

/// 不美颜 / 自动 / 自然 / 精致: the marker slides to the one chosen.
struct LevelBar: View {
    @EnvironmentObject var studio: Studio
    @Namespace private var space

    var body: some View {
        // Chinese names are two or three characters and the four share the width; where a language's names are
        // longer, each segment takes what its word needs, then smaller type, and only then is a word squeezed
        ViewThatFits(in: .horizontal) {
            row(size: 13, fixed: true)
            row(size: 11.5, fixed: true)
            row(size: 11.5, fixed: false)
        }
    }

    private func row(size: CGFloat, fixed: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(BeautyLevel.allCases) { level in
                let on = studio.level == level
                Button { withAnimation(DS.pick) { studio.level = level } } label: {
                    Text(level.title).font(.system(size: size, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? DS.onFocus : DS.ink)
                        .lineLimit(1).minimumScaleFactor(fixed ? 1 : 0.7).fixedSize(horizontal: fixed, vertical: false)
                        .padding(.horizontal, fixed ? 9 : 4)
                        .frame(maxWidth: .infinity).frame(height: DS.touch - 6)
                        .background { if on { Capsule().fill(DS.focus).matchedGeometryEffect(id: "level", in: space) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.faint, in: Capsule())
    }
}

struct ShapeChip: View {
    @EnvironmentObject var studio: Studio
    let key: String, title: String

    var body: some View {
        let on = studio.shapes.contains(key)
        Button {
            withAnimation(.bouncy(duration: 0.3)) { if on { studio.shapes.remove(key) } else { studio.shapes.insert(key) } }
        } label: {
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                .lineLimit(2).multilineTextAlignment(.center).lineSpacing(-2)      // two words may take two lines
                .minimumScaleFactor(0.7).padding(.horizontal, 4)
                .foregroundStyle(on ? DS.onFocus : DS.ink)
                .frame(maxWidth: .infinity).frame(height: DS.touch)
                .background(on ? AnyShapeStyle(DS.focus) : AnyShapeStyle(DS.faint), in: RoundedRectangle(cornerRadius: DS.chip, style: .continuous))
                .scaleEffect(on ? 1 : 0.97)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ShapeChips: View {
    static let all = [("slim", L.shapeSlim), ("bigeyes", L.shapeEyes), ("waist", L.shapeWaist), ("chest", L.shapeChest), ("legs", L.shapeLegs), ("light", L.shapeLight)]
    var columns = 3
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 56), spacing: 8), count: columns), spacing: 8) {
            ForEach(Self.all, id: \.0) { ShapeChip(key: $0.0, title: $0.1) }
        }
    }
}

/// One person of the shoot: their face, and under it what was chosen for them. Each press moves on:
/// 跟随 → 轻 → 自然 → 精致 → 不修.
struct PersonChip: View {
    @EnvironmentObject var studio: Studio
    let person: Person
    static let names = ["follow": L.personFollow, "light": L.personLight, "natural": L.levelNatural, "refined": L.levelRefined, "off": L.personOff]
    static let order = ["follow", "light", "natural", "refined", "off"]

    var body: some View {
        let chosen = studio.choices[person.id] ?? "follow"
        let own = chosen != "follow"
        Button {
            let next = Self.order[((Self.order.firstIndex(of: chosen) ?? 0) + 1) % Self.order.count]
            withAnimation(DS.pick) { studio.choose(next, for: person) }
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: person.image).resizable().scaledToFill().frame(width: DS.touch, height: DS.touch).clipShape(Circle())
                    .overlay(Circle().strokeBorder(own ? DS.focus : DS.faint, lineWidth: own ? 2 : 1))
                    .saturation(chosen == "off" ? 0 : 1).opacity(chosen == "off" ? 0.5 : 1)
                Text(Self.names[chosen] ?? L.personFollow).font(.system(size: 11, weight: own ? .semibold : .regular))
                    .foregroundStyle(own ? DS.focus : DS.soft)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.interpolate)
            }
            .frame(width: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        Toggle(isOn: $on) { Text(title).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true) }
            .toggleStyle(.switch).tint(DS.focus)
            .frame(minHeight: DS.touch)
    }
}

/// What a control does, for those who want to know: pressed, not hovered.
struct InfoButton: View {
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(DS.soft)
                .frame(width: DS.touch, height: DS.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(L.explain)
        .popover(isPresented: $showing, arrowEdge: .leading) {
            Text(text).font(DS.body).fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 300, alignment: .leading)
        }
    }
}
