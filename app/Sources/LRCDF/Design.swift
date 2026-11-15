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

extension View {
    /// Smoked Liquid Glass. `clear` for small labels that sit on the photo itself.
    func glass<S: Shape>(_ shape: S, smoked: Bool = true, interactive: Bool = false, clear: Bool = false) -> some View {
        glassEffect((clear ? Glass.clear : Glass.regular).tint(smoked && !clear ? DS.smoke : nil).interactive(interactive), in: shape)
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

/// 暗 ●●●●● 亮: press an end to go one step, or slide along the dots. Five stops, never a free slider.
/// A row of a `Grid` (see `Tweaks`).
struct StepRow: View {
    let low: String, high: String
    @Binding var value: Int
    @Namespace private var space

    var body: some View {
        GridRow {
            end(low) { if value > -2 { value -= 1 } }
            GeometryReader { box in
                HStack(spacing: 0) {
                    ForEach(-2...2, id: \.self) { step in
                        ZStack {
                            Circle().fill(step == 0 ? DS.soft : DS.faint).frame(width: step == 0 ? 5 : 4, height: step == 0 ? 5 : 4)
                            if step == value {
                                Circle().fill(value == 0 ? DS.ink : DS.focus).frame(width: 14, height: 14)
                                    .matchedGeometryEffect(id: "knob", in: space)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background { Capsule().fill(DS.faint).frame(height: 2) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let next = min(2, max(-2, Int((drag.location.x / max(box.size.width, 1) * 5).rounded(.down)) - 2))
                    if next != value { withAnimation(DS.pick) { value = next } }
                })
            }
            .frame(minWidth: 90).frame(height: DS.touch)
            end(high) { if value < 2 { value += 1 } }
        }
    }

    private func end(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(DS.pick) { action() } } label: {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.ink)
                .lineLimit(1).fixedSize()        // one character in Chinese, a word elsewhere: the column takes the widest
                .padding(.horizontal, 6).frame(minWidth: DS.touch, minHeight: DS.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 不美颜 / 自动 / 自然 / 精致: the marker slides to the one chosen.
struct LevelBar: View {
    @EnvironmentObject var studio: Studio
    @Namespace private var space

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BeautyLevel.allCases) { level in
                let on = studio.level == level
                Button { withAnimation(DS.pick) { studio.level = level } } label: {
                    Text(level.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? DS.onFocus : DS.ink)
                        .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 4)
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
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
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
