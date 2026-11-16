import AppKit
import SwiftUI

/// How a new picture comes in over the one before it. A look comes from the side its card is on; retouching opens
/// from the face; only a more exact render of the same thing (Lightroom's own, replacing the quick guess) just settles.
enum Reveal: Equatable { case wipe(leading: Bool), iris, settle }

struct RevealImage: View {
    let image: NSImage
    let look: Int               // where the look's card is in the row
    let level: String
    let retouched: Bool
    let origin: UnitPoint       // the face, as a fraction of the picture
    @State private var shown: NSImage?
    @State private var incoming: NSImage?
    @State private var style: Reveal = .settle
    @State private var progress: CGFloat = 0
    @State private var token = 0
    @State private var last: (look: Int, level: String, retouched: Bool)?
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        ZStack {
            Image(nsImage: shown ?? image).resizable().interpolation(.high)
            if let incoming {
                if style == .settle {
                    Image(nsImage: incoming).resizable().interpolation(.high).opacity(progress)
                } else {
                    Image(nsImage: incoming).resizable().interpolation(.high)
                        .mask { RevealMask(progress: progress, style: style, origin: origin).blur(radius: 18) }
                }
            }
        }
        .onAppear { last = (look, level, retouched) }
        .onChange(of: ObjectIdentifier(image)) { _, _ in
            let before = last ?? (look, level, retouched)
            last = (look, level, retouched)
            let next: Reveal = calm ? .settle : look != before.look ? .wipe(leading: look < before.look)
                : (level != before.level || retouched != before.retouched ? .iris : .settle)
            if let incoming { shown = incoming }
            token += 1
            let mine = token
            style = next; incoming = image; progress = 0
            let time = next == .iris ? DS.iris : (next == .settle ? 0.25 : DS.wipe)
            withAnimation(.smooth(duration: time)) { progress = 1 } completion: {
                if mine == token { shown = image; incoming = nil }
            }
        }
    }
}

struct RevealMask: Shape {
    var progress: CGFloat
    let style: Reveal
    let origin: UnitPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .settle: return Path(rect)
        case .wipe(let leading):
            let w = (rect.width + 60) * progress
            return Path(CGRect(x: leading ? rect.minX - 30 : rect.maxX + 30 - w, y: rect.minY - 30, width: w, height: rect.height + 60))
        case .iris:
            let c = CGPoint(x: rect.minX + rect.width * origin.x, y: rect.minY + rect.height * origin.y)
            let far = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                       CGPoint(x: rect.maxX, y: rect.maxY)].map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? rect.width
            let r = (far + 40) * progress
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }
}

/// The photo, fitted into what the floating controls leave free: the original left of the divider, the result right.
///
/// Hands and pointers do the same things:
/// - the divider is taken by its line or its handle (a 44 pt column) and nowhere else; let go and it carries on a
///   little and settles; thrown at an edge it goes all the way; a double tap on it brings it back to the middle
/// - pinch, the mouse wheel, the buttons or a double tap zoom; a zoomed picture is moved by dragging
/// - a sideways swipe on a picture that fits goes to the next or the previous photo (as do ← →)
struct Canvas: View {
    @EnvironmentObject var studio: Studio
    @State private var pinchedTo: CGFloat = 1    // the pinch's magnification so far: each change zooms by the step from it
    let before: NSImage
    let after: NSImage
    var title = ""
    var plain = false            // nothing changes the picture: no divider
    var retouched = false
    var pending = false
    var sweep: Double? = nil     // while Lightroom works: the result spreads over the photo as far as the work has got
    var clear: EdgeInsets
    var ids: [Int] = []          // the photos a swipe steps through

    var body: some View {
        GeometryReader { box in
            let area = CGSize(width: max(60, box.size.width - clear.leading - clear.trailing),
                              height: max(60, box.size.height - clear.top - clear.bottom))
            let ratio = before.size.width / max(before.size.height, 1)
            let w = min(area.width, area.height * ratio), h = w / ratio
            let centre = CGPoint(x: clear.leading + area.width / 2, y: clear.top + area.height / 2)
            ZStack {
                // the whole free area takes a pinch, not only the picture: a portrait leaves much of the room beside it
                // (the user pinched there and nothing happened)
                Color.clear.contentShape(Rectangle())
                    .background(ScrollCatcher(kinds: .magnify) { _, _, pinched, place, _ in
                        guard sweep == nil, pinched != 0 else { return }
                        // from the free area to the picture in its middle (outside the picture: its nearest edge)
                        let at = CGPoint(x: min(1, max(0, (place.x * area.width - (area.width - w) / 2) / max(w, 1))),
                                         y: min(1, max(0, (place.y * area.height - (area.height - h) / 2) / max(h, 1))))
                        studio.zoom(by: 1 + pinched, at: at)
                    })
                    .frame(width: area.width, height: area.height).position(centre)
                Pane(before: before, after: after, title: title, plain: plain, retouched: retouched, pending: pending,
                     sweep: sweep, ids: ids, w: w, h: h)
                    .frame(width: w, height: h)
                    .position(centre)
                    .id(studio.photo)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            // A fallback: the catcher above takes the trackpad's pinch events first (and keeps them), so this only acts
            // if they ever arrive some other way - never both
            .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0).onChanged { value in
                guard sweep == nil else { return }
                let step = value.magnification / max(pinchedTo, 0.01)
                pinchedTo = value.magnification
                // around the fingers, as a fraction of the picture (outside it: its nearest edge)
                let at = CGPoint(x: min(1, max(0, (value.startLocation.x - (centre.x - w / 2)) / max(w, 1))),
                                 y: min(1, max(0, (value.startLocation.y - (centre.y - h / 2)) / max(h, 1))))
                studio.zoom(by: step, at: at)
            }.onEnded { _ in pinchedTo = 1 })
        }
    }
}

private struct Pane: View {
    @EnvironmentObject var studio: Studio
    let before: NSImage, after: NSImage
    let title: String
    let plain: Bool, retouched: Bool, pending: Bool
    let sweep: Double?
    let ids: [Int]
    let w: CGFloat, h: CGFloat
    @AppStorage("divider") private var kept = 0.5
    @State private var split: CGFloat = 0.5
    @State private var grabbed = false
    @State private var panFrom: CGPoint?
    @State private var pull: CGFloat = 0           // sideways give while swiping to another photo
    @State private var swiped: CGFloat = 0         // two-finger sideways scrolling, summed up
    @State private var marked = false              // focus brackets on the face just jumped to

    private var working: Bool { sweep != nil }
    private var here: Int? { ids.firstIndex(of: studio.photo) }

    private func step(_ by: Int) {
        guard let here, ids.indices.contains(here + by) else { return }
        studio.show(ids[here + by])
    }

    var body: some View {
        let zoom = studio.zoom
        let shift = CGSize(width: (0.5 - studio.centre.x) * w * zoom, height: (0.5 - studio.centre.y) * h * zoom)
        let x = w * (sweep.map { CGFloat(min(1, max(0, 1 - $0))) } ?? split)
        let face = studio.face.flatMap { studio.faces.indices.contains($0) ? studio.faces[$0] : nil }
        let lookAt = studio.looks.firstIndex { $0.id == studio.look } ?? 0
        ZStack(alignment: .topLeading) {
            RevealImage(image: after, look: lookAt, level: studio.level.rawValue, retouched: retouched,
                        origin: studio.faces.first.map { UnitPoint(x: $0.midX, y: $0.midY) } ?? .center)
                .frame(width: w, height: h).scaleEffect(zoom).offset(shift)
            if !plain {
                Image(nsImage: before).resizable().interpolation(.high)
                    .frame(width: w, height: h).scaleEffect(zoom).offset(shift)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, x)) }
            }
            if let face, marked {
                FocusMark(arm: 14)
                    .frame(width: face.width * w * zoom, height: face.height * h * zoom)
                    .offset(x: (face.minX - studio.centre.x) * w * zoom + w / 2, y: (face.minY - studio.centre.y) * h * zoom + h / 2)
                    .transition(.scale(scale: 1.5).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: DS.photo, style: .continuous))
        .overlay(alignment: .topLeading) { if !working { labels(x) } }
        .overlay(alignment: .topLeading) { if !plain { divider(x) } }
        .offset(x: pull)
        .contentShape(Rectangle())
        .coordinateSpace(name: "pane")
        .background(ScrollCatcher(kinds: .scrollWheel) { wheel, scrolled, _, place, ended in
            guard !working else { return }
            if wheel != 0 {
                studio.zoom(by: wheel > 0 ? 1.18 : 1 / 1.18, at: place)
            } else if studio.zoom > 1.01 {
                studio.look(at: CGPoint(x: studio.centre.x - scrolled.width / (w * studio.zoom),
                                        y: studio.centre.y - scrolled.height / (h * studio.zoom)))
            } else if ended {
                swiped = 0
            } else if swiped.isFinite {             // two fingers sideways on a picture that fits: another photo
                swiped += scrolled.width
                if abs(swiped) > 110 { step(swiped < 0 ? 1 : -1); swiped = .infinity }      // one photo per swipe
            }
        })
        .gesture(DragGesture(minimumDistance: 10).onChanged { drag in
            guard !working else { return }
            if studio.zoom > 1.01 {
                if panFrom == nil { panFrom = studio.centre }
                studio.look(at: CGPoint(x: panFrom!.x - drag.translation.width / (w * studio.zoom),
                                        y: panFrom!.y - drag.translation.height / (h * studio.zoom)))
            } else if let here {
                let can = drag.translation.width < 0 ? here + 1 < ids.count : here > 0
                pull = drag.translation.width * (can ? 0.45 : 0.1)       // stiff when there is nothing that way
            }
        }.onEnded { drag in
            panFrom = nil
            guard studio.zoom <= 1.01, !working else { return }
            let flung = drag.predictedEndTranslation.width
            if abs(flung) > 160 { step(flung < 0 ? 1 : -1) }
            withAnimation(.spring(duration: 0.4, bounce: 0.25)) { pull = 0 }
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            guard !working else { return }
            withAnimation(DS.zoom) {
                if studio.zoom > 1.01 { studio.zoom = 1; studio.centre = CGPoint(x: 0.5, y: 0.5); studio.face = nil }
                else { studio.zoom(by: 3, at: CGPoint(x: tap.location.x / max(w, 1), y: tap.location.y / max(h, 1))) }
            }
        })
        .onAppear { split = kept }
        .onChange(of: studio.face) { _, now in
            guard now != nil else { marked = false; return }
            withAnimation(.spring(duration: 0.3)) { marked = true }
            let which = now
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                if studio.face == which { withAnimation(.easeOut(duration: 0.3)) { marked = false } }
            }
        }
        .animation(.linear(duration: 0.4), value: sweep)
    }

    @ViewBuilder private func labels(_ x: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            tag { Text(L.original) }
                .padding(12).opacity(plain || x > 84 ? 1 : 0)
            if !plain {
                tag {
                    if pending { ProgressView().controlSize(.mini) }
                    Text(pending ? L.pendingLabel(title) : (retouched ? L.retouchedLabel(title) : title)).contentTransition(.interpolate)
                }
                .padding(12).frame(width: w, alignment: .topTrailing).opacity(x < w - 150 ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: x > 84)
        .animation(.easeOut(duration: 0.15), value: x < w - 150)
        .allowsHitTesting(false)
    }

    private func tag<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 26)
            .glass(Capsule())          // smoked, not clear: over a bright sky clear glass turned white and hid the white type
    }

    @ViewBuilder private func divider(_ x: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: grabbed ? 2.5 : 1.5).shadow(color: .black.opacity(0.45), radius: 3)
            if !working {
                HandleArrows()
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: DS.touch, height: DS.touch)
                    .glass(Circle(), smoked: false, interactive: true)
                    .scaleEffect(grabbed ? 1.14 : 1)
                    .offset(y: h / 2 - 54)          // low, out of the face's way and near the hand
            }
        }
        .frame(width: DS.touch, height: h)
        .contentShape(Rectangle())
        .offset(x: x - DS.touch / 2)
        .allowsHitTesting(!working)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("pane")).onChanged { drag in
            if !grabbed { withAnimation(.spring(duration: 0.2)) { grabbed = true } }
            split = min(1, max(0, drag.location.x / max(w, 1)))
        }.onEnded { drag in
            var rest = min(1, max(0, drag.predictedEndLocation.x / max(w, 1)))
            if rest < 0.07 { rest = 0 } else if rest > 0.93 { rest = 1 }
            withAnimation(DS.settle) { split = rest; grabbed = false }
            kept = rest
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { split = 0.5 }
            kept = 0.5
        })
        .accessibilityLabel(L.divider)
    }
}

/// Catches the mouse wheel, two-finger scrolling or pinching over a view. The picture takes the wheel and scrolling;
/// pinching is taken over the whole free area around it (Canvas), so a portrait can be pinched beside it too.
struct ScrollCatcher: NSViewRepresentable {
    let kinds: NSEvent.EventTypeMask
    /// (wheel steps, scrolled by, pinched by, where: 0…1 across the view from the top left, the fingers have left)
    let handler: (CGFloat, CGSize, CGFloat, CGPoint, Bool) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(kinds: kinds, handler: handler) }
    func updateNSView(_ view: Catcher, context: Context) { view.handler = handler }

    final class Catcher: NSView {
        var handler: (CGFloat, CGSize, CGFloat, CGPoint, Bool) -> Void
        private let kinds: NSEvent.EventTypeMask
        private var monitor: Any?

        init(kinds: NSEvent.EventTypeMask, handler: @escaping (CGFloat, CGSize, CGFloat, CGPoint, Bool) -> Void) {
            self.kinds = kinds
            self.handler = handler
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.width > 1 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let place = CGPoint(x: point.x / self.bounds.width, y: 1 - point.y / self.bounds.height)
                if event.type == .magnify {
                    self.handler(0, .zero, event.magnification, place, false)
                } else if event.hasPreciseScrollingDeltas {      // trackpad: two fingers move the picture, or step
                    let over = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
                    if event.momentumPhase == [] || over {       // coasting after the fingers left does not count
                        self.handler(0, CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), 0, place, over)
                    }
                } else {                                         // mouse wheel: zoom
                    self.handler(event.scrollingDeltaY, .zero, 0, place, false)
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// − 适合窗口 + and the jump from face to face, as one piece of glass.
struct ZoomCluster: View {
    @EnvironmentObject var studio: Studio
    var compact = false          // where room is short the face button is its symbol alone

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", label: L.zoomOut) { withAnimation(DS.zoom) { studio.zoom(by: 1 / 1.5) } }.disabled(studio.zoom <= 1)
            Button(action: studio.fit) {
                Text(studio.zoom <= 1.01 ? L.fit : Double(studio.zoom).formatted(.number.precision(.fractionLength(1))) + "×")
                    .font(DS.label).monospacedDigit().contentTransition(.numericText())
                    .lineLimit(1).fixedSize().padding(.horizontal, 6)
                    .frame(minWidth: 64, minHeight: DS.touch).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(symbol: "plus", label: L.zoomIn) { withAnimation(DS.zoom) { studio.zoom(by: 1.5) } }.disabled(studio.zoom >= 8)
            if !studio.faces.isEmpty {
                Rectangle().fill(DS.line).frame(width: 1, height: 20)
                Button(action: studio.nextFace) {
                    let title = studio.face == nil ? L.toFace : (studio.face! + 1 < min(studio.faces.count, 4) ? L.nextFace : L.wholePicture)
                    Group {
                        if compact { Label(title, systemImage: "face.smiling").labelStyle(.iconOnly) }
                        else { Label(title, systemImage: "face.smiling").lineLimit(1).fixedSize() }
                    }
                    .font(DS.label).contentTransition(.interpolate)
                    .padding(.horizontal, 14).frame(minWidth: DS.touch, minHeight: DS.touch).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .foregroundStyle(DS.ink)
        .glass(Capsule(), interactive: true)
        .help(L.zoomHelp)
    }
}

/// ‹ 3 / 12 › and the photo's name, in the top row. The arrows, ← → and a sideways swipe all do the same.
struct PhotoStepper: View {
    @EnvironmentObject var studio: Studio
    let ids: [Int]
    var name: String?

    var body: some View {
        let here = ids.firstIndex(of: studio.photo)
        HStack(spacing: 0) {
            if ids.count > 1 {
                IconButton(symbol: "chevron.left", label: L.previous) { if let here, here > 0 { studio.show(ids[here - 1]) } }
                    .disabled((here ?? 0) == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Text(L.position((here ?? 0) + 1, ids.count)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText()).frame(minWidth: 44)
                IconButton(symbol: "chevron.right", label: L.next) { if let here, here + 1 < ids.count { studio.show(ids[here + 1]) } }
                    .disabled((here ?? 0) + 1 >= ids.count).keyboardShortcut(.rightArrow, modifiers: [])
            }
            if let name, !name.isEmpty {
                Text(name).font(.system(size: 12)).foregroundStyle(DS.soft).lineLimit(1)
                    .padding(.leading, ids.count > 1 ? 2 : 16).padding(.trailing, 16).frame(height: DS.touch)
            }
        }
        .foregroundStyle(DS.ink)
        .glass(Capsule(), interactive: true)
    }
}


/// ‹› on the divider's handle. The symbol is new in macOS 15 (it would be blank on 14): there two single chevrons.
struct HandleArrows: View {
    var body: some View {
        if #available(macOS 15, *), !DS.forceOldLook { Image(systemName: "chevron.left.chevron.right") }
        else { HStack(spacing: 1) { Image(systemName: "chevron.left"); Image(systemName: "chevron.right") }.scaleEffect(0.82) }
    }
}
