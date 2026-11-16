import PhotosUI
import SwiftUI

/// The editor, after the Mac app's layout (docs/design/FOR_IPAD.md): the room behind everything; wide (>= 1000 pt) =
/// photo with the inspector on the right and every look in a tray along the bottom; narrow = photo, tray, inspector.
struct EditorView: View {
    @EnvironmentObject var studio: Studio
    @Binding var picks: [PhotosPickerItem]
    @Binding var showFiles: Bool
    @State private var settings = false
    @State private var confirmClear = false
    @State private var tethering = false
    @ObservedObject private var tether = Tether.shared

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= DS.wide && geo.size.width > geo.size.height     // portrait: photo, tray, panel
            ZStack {
                Room(image: studio.picture)
                VStack(spacing: DS.gap) {
                    topBar(compact: geo.size.width < 1100)
                    if wide {
                        HStack(spacing: DS.gap) {
                            PictureView()
                            Inspector().frame(width: DS.side)
                                .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
                        }
                        .frame(maxHeight: .infinity).layoutPriority(-1)       // the tray keeps its height
                        LookTray(height: 128)
                    } else {
                        PictureView()
                        LookTray(height: 120)
                        Inspector().frame(height: min(430, geo.size.height * 0.42))
                            .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
                    }
                }
                .padding(DS.gap)
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: studio.look) { _, _ in studio.settingsChanged() }
        .onChange(of: studio.tweak) { _, _ in studio.settingsChanged() }
        .onChange(of: studio.beauty) { _, _ in studio.settingsChanged() }
        .onChange(of: studio.beautyAmount) { _, _ in studio.settingsChanged() }
        .onChange(of: studio.shapes) { _, _ in studio.settingsChanged() }
        .onChange(of: studio.denoise) { _, _ in studio.settingsChanged() }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $tethering) { TetherView().environmentObject(studio) }
    }

    /// The photos of this session, then adding more and 设置. `compact` (under 1100 pt: iPad mini, any iPad upright):
    /// icon-only buttons, a narrower photo strip and the progress as words only. With the full labels the row was wider
    /// than the iPad mini's screen and pushed the whole editor to the right (user 2026-11-16).
    private func topBar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if studio.photos.count > 1 {
                Scrolling(axis: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(studio.photos) { p in
                            let on = p.id == studio.current
                            Button { withAnimation(DS.pick) { studio.select(p.id) } } label: {
                                Group {
                                    if let t = p.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() }
                                    else { ProgressView().controlSize(.small) }
                                }
                                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .padding(4).overlay { if on { FocusMark(arm: 8) } }
                                .opacity(on ? 1 : 0.7)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
                .frame(height: 56)
                // the strip takes only what the buttons leave (lower layout priority), at most what its photos need:
                // a fixed width made the row wider than the iPad mini's landscape screen and pushed everything right
                .frame(maxWidth: min(compact ? 160 : 480, CGFloat(studio.photos.count) * 58 + 20), alignment: .leading)
                .glass(Capsule())
                .layoutPriority(-1)
            }
            if let pr = studio.progress { ProgressLine(done: pr.done, total: pr.total, text: pr.what, compact: compact) }
            Spacer(minLength: 0).layoutPriority(-2)
            TetherBadge { tethering = true }
            PhotosPicker(selection: $picks, matching: .images, preferredItemEncoding: .current) {
                if compact { Image(systemName: "plus") } else { Label("加照片", systemImage: "plus") }
            }.buttonStyle(QuietButton()).accessibilityLabel("加照片")
            Button { showFiles = true } label: { if compact { Image(systemName: "folder") } else { Label("从文件", systemImage: "folder") } }
                .buttonStyle(QuietButton()).accessibilityLabel("从文件")
            #if os(iOS)
            if !tether.on {          // while receiving, the "联机中" badge opens the same page
                Button { tethering = true } label: { if compact { Image(systemName: "camera") } else { Label("联机拍摄", systemImage: "camera") } }
                    .buttonStyle(QuietButton()).accessibilityLabel("联机拍摄")
            }
            #endif
            Button { confirmClear = true } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton())
                .accessibilityLabel("清空，重新选照片")
                .confirmationDialog("清空这些照片，重新选？", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { studio.clear() }
                } message: { Text("只是从这里拿走，相册和文件里的原片不受影响；没存的修图效果会丢掉。") }
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: DS.touch, height: DS.touch)
                    .overlay(alignment: .topTrailing) {
                        if UpdateNotice.shared.newer != nil || UpdateNotice.shared.offering { Circle().fill(DS.focus).frame(width: 8, height: 8).padding(8) }
                    }
                    .glass(Circle(), interactive: true)
            }.buttonStyle(.plain).accessibilityLabel("设置")
        }
        .foregroundStyle(DS.ink)
    }
}

/// The photo, large: the original left of the divider, the result right of it (as the Mac app). Drag the divider or
/// its handle; a double tap on it brings it back to the middle.
struct PictureView: View {
    @EnvironmentObject var studio: Studio
    @AppStorage("divider") private var kept = 0.5
    @State private var split: CGFloat = 0.5
    @State private var grabbed = false
    // zoom (user: "修图的时候通过手指放大缩小"): 1…8, and the picture point (0…1) at the middle of the view
    @State private var zoom: CGFloat = 1
    @State private var centre = CGPoint(x: 0.5, y: 0.5)
    @State private var pinchFrom: (CGFloat, CGPoint)?
    @State private var panFrom: CGPoint?

    var body: some View {
        GeometryReader { box in
            if let pic = studio.picture {
                let ratio = CGFloat(pic.width) / CGFloat(max(pic.height, 1))
                let area = CGSize(width: box.size.width, height: box.size.height)
                let w = min(area.width, area.height * ratio), h = w / ratio
                let x = w * split
                let shift = CGSize(width: (0.5 - centre.x) * w * zoom, height: (0.5 - centre.y) * h * zoom)
                ZStack(alignment: .topLeading) {
                    Group {
                        Image(decorative: pic, scale: 1).resizable().frame(width: w, height: h)
                            .scaleEffect(zoom).offset(shift)
                        if let orig = studio.originalPicture {
                            Image(decorative: orig, scale: 1).resizable().frame(width: w, height: h)
                                .scaleEffect(zoom).offset(shift)
                                .mask(alignment: .leading) { Rectangle().frame(width: max(0, x)) }
                        }
                    }
                    .frame(width: w, height: h).contentShape(Rectangle())
                    .gesture(pinch(w, h).simultaneously(with: pan(w, h)))
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { t in
                        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
                            if zoom > 1.01 { zoom = 1; centre = CGPoint(x: 0.5, y: 0.5) }
                            else { zoomTo(3, at: UnitPoint(x: t.location.x / w, y: t.location.y / h), from: 1, centre: centre) }
                        }
                    })
                    labels(x, w)
                    divider(x, h, w)
                    if zoom > 1.01 {
                        Text(String(format: "%.1f×", zoom)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 11).frame(height: 28).glass(Capsule(), clear: true)
                            .padding(12).frame(width: w, height: h, alignment: .bottomTrailing).allowsHitTesting(false)
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: DS.photo, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .coordinateSpace(name: "pane")
                .position(x: box.size.width / 2, y: box.size.height / 2)
            } else {
                ProgressView("正在打开照片…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { split = kept }
        .onChange(of: studio.current) { _, _ in zoom = 1; centre = CGPoint(x: 0.5, y: 0.5) }   // a new photo starts whole
    }

    /// Two fingers: zoom about the point between them (that point stays under the fingers).
    private func pinch(_ w: CGFloat, _ h: CGFloat) -> some Gesture {
        MagnifyGesture().onChanged { v in
            if pinchFrom == nil { pinchFrom = (zoom, centre) }
            let (z0, c0) = pinchFrom!
            zoomTo(z0 * v.magnification, at: v.startAnchor, from: z0, centre: c0)
        }.onEnded { _ in
            pinchFrom = nil
            if zoom < 1.05 { withAnimation(.spring(duration: 0.35)) { zoom = 1; centre = CGPoint(x: 0.5, y: 0.5) } }
        }
    }

    /// One finger on a zoomed picture moves it (the divider keeps its own gesture).
    private func pan(_ w: CGFloat, _ h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8).onChanged { d in
            guard zoom > 1.01, pinchFrom == nil else { return }
            if panFrom == nil { panFrom = centre }
            centre = clamped(CGPoint(x: panFrom!.x - d.translation.width / (w * zoom), y: panFrom!.y - d.translation.height / (h * zoom)), zoom)
        }.onEnded { _ in panFrom = nil }
    }

    /// Zoom to `z` keeping the picture point under `anchor` (0…1 of the view) where it is.
    private func zoomTo(_ z: CGFloat, at anchor: UnitPoint, from z0: CGFloat, centre c0: CGPoint) {
        let nz = min(8, max(1, z))
        let p = CGPoint(x: c0.x + (anchor.x - 0.5) / z0, y: c0.y + (anchor.y - 0.5) / z0)       // picture point under the fingers
        zoom = nz
        centre = clamped(CGPoint(x: p.x - (anchor.x - 0.5) / nz, y: p.y - (anchor.y - 0.5) / nz), nz)
    }

    /// The view never shows beyond the picture's edges.
    private func clamped(_ c: CGPoint, _ z: CGFloat) -> CGPoint {
        let m = 0.5 / z
        return CGPoint(x: min(1 - m, max(m, c.x)), y: min(1 - m, max(m, c.y)))
    }

    private var rightLabel: String {
        let look = Look.all.first { $0.id == studio.look }?.title ?? ""
        let face = !(studio.currentPhoto?.faces.isEmpty ?? true) && studio.beauty != .off
        if !(studio.currentPhoto?.analysed ?? true) { return look + " · 正在找人脸…" }
        return face ? look + " + 美颜" : look
    }

    @ViewBuilder private func labels(_ x: CGFloat, _ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            tag("原图").padding(12).opacity(x > 84 ? 1 : 0)
            tag(rightLabel).padding(12).frame(width: w, alignment: .topTrailing).opacity(x < w - 170 ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: x > 84)
        .allowsHitTesting(false)
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 28)
            .glass(Capsule(), clear: true)
    }

    @ViewBuilder private func divider(_ x: CGFloat, _ h: CGFloat, _ w: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: grabbed ? 2.5 : 1.5).shadow(color: .black.opacity(0.45), radius: 3)
            Image(systemName: "chevron.left.chevron.right")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glass(Circle(), smoked: false, interactive: true)
                .scaleEffect(grabbed ? 1.14 : 1)
                .offset(y: h / 2 - 54)          // low, out of the face's way and near the hand
        }
        .frame(width: 44, height: h)
        .contentShape(Rectangle())
        .offset(x: x - 22)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pane")).onChanged { drag in
            if !grabbed { withAnimation(.spring(duration: 0.2)) { grabbed = true } }
            split = min(1, max(0, drag.location.x / max(w, 1)))
        }.onEnded { drag in
            var rest = min(1, max(0, drag.predictedEndLocation.x / max(w, 1)))
            if rest < 0.07 { rest = 0 } else if rest > 0.93 { rest = 1 }
            withAnimation(.spring(duration: 0.35)) { split = rest; grabbed = false }
            kept = rest
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { split = 0.5 }
            kept = 0.5
        })
        .accessibilityLabel("左右拖动，对比原图和修好的")
    }
}


/// The right-hand panel: the chosen look's name, the three tweaks, retouching, and the one action.
struct Inspector: View {
    @EnvironmentObject var studio: Studio
    @Namespace private var space

    nonisolated(unsafe) static var layout = 2      // folded groups, one open at a time (user's choice, docs/ipad/面板布局_四种.jpg)
    static let shapingReady = true                // the 塑形 group (Shaping.swift)
    @State private var tab = 1                     // layout 1: 0 调色, 1 美颜, 2 塑形
    nonisolated(unsafe) static var startOpen = 1   // which group is open at first (self-test: 调色)
    @State private var open = Inspector.startOpen  // layout 2: which section is open

    var body: some View {
        let look = Look.all.first { $0.id == studio.look }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(look?.title ?? "").font(DS.display(32)).contentTransition(.interpolate)
                Text(look?.note ?? "").font(DS.body).foregroundStyle(DS.soft)
            }
            .animation(DS.pick, value: studio.look)
            .padding([.horizontal, .top], DS.pad).padding(.bottom, 12)
            if Self.layout == 1 { tabs.padding(.horizontal, DS.pad).padding(.bottom, 6) }
            Scrolling {
                VStack(alignment: .leading, spacing: 16) {
                    switch Self.layout {
                    case 1:
                        switch tab { case 0: tone; case 1: beauty; default: shaping }
                    case 2:
                        fold(0, "调色", studio.tweak.isZero ? "跟着风格" : "已微调") { tone }
                        fold(1, "美颜", studio.beauty.title) { beauty }
                        if Self.shapingReady { fold(2, "塑形", shapeCount == 0 ? "未开启" : "\(shapeCount) 项") { shaping } }
                    case 3:
                        group { tone }
                        group { beauty }
                        group { shaping }
                    default:
                        tone
                        Rectangle().fill(DS.line).frame(height: 1)
                        beauty
                    }
                }
                .padding(.horizontal, DS.pad).padding(.bottom, DS.pad).padding(.top, 4)
            }
            VStack(spacing: 8) { action }
                .padding(.horizontal, DS.pad).padding(.bottom, DS.pad).padding(.top, 6)
        }
        .foregroundStyle(DS.ink)
    }

    @ViewBuilder private var tone: some View {
        if Self.layout != 1 && Self.layout != 2 { Text("调色").font(DS.section) }
        VStack(spacing: 2) {
            ToneSlider(low: "暗", high: "亮", value: $studio.tweak.bright)
            WheelPicker(tweak: $studio.tweak).padding(.vertical, 6)
            ToneSlider(low: "淡", high: "浓", value: $studio.tweak.rich)
            ToneSlider(low: "柔", high: "硬", value: $studio.tweak.contrast)
            ToneSlider(low: "压", high: "提", value: $studio.tweak.highlights, caption: "高光")
            ToneSlider(low: "暗", high: "亮", value: $studio.tweak.shadows, caption: "阴影")
        }
        HStack {
            Text("拖动微调；点数字或双击滑块回到中间").font(DS.note).foregroundStyle(DS.soft)
            Spacer()
            if !studio.tweak.isZero {
                Button("还原") { withAnimation(DS.pick) { studio.tweak = studio.tweak.reset } }
                    .font(DS.label).foregroundStyle(DS.focus).buttonStyle(.plain)
            }
        }
        // 降噪: one switch for the batch (as on the Mac); the line under it says which photos it changes
        Toggle(isOn: $studio.denoise) {
            Text(String(localized: "ipad.denoise.title", defaultValue: "降噪", comment: "Switch: colour-noise reduction of JPEG/HEIC photos. Not AI.")).font(DS.section)
        }
        .tint(DS.focus).frame(minHeight: DS.touch)
        Text(studio.denoiseNote).font(DS.note).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
    }

    /// 瘦脸 大眼 收腰 丰胸 长腿 匀光: switches, as the Mac app's chips.
    @ViewBuilder private var shaping: some View {
        if Self.layout != 1 && Self.layout != 2 { Text("塑形").font(DS.section) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach([("slim", "瘦脸", "face.smiling"), ("eyes", "大眼", "eye"), ("waist", "收腰", "figure.stand"),
                     ("chest", "丰胸", "heart"), ("legs", "长腿", "figure.walk"), ("light", "匀光", "sun.max")], id: \.0) { k, t, icon in
                let on = shapeOn(k).wrappedValue
                Button { withAnimation(.bouncy(duration: 0.3)) { shapeOn(k).wrappedValue.toggle() } } label: {
                    VStack(spacing: 4) {
                        if Self.layout == 3 { Image(systemName: icon).font(.system(size: 16)) }
                        Text(t).font(.system(size: 14, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? DS.onFocus : DS.ink)
                    .frame(maxWidth: .infinity).frame(height: Self.layout == 3 ? 56 : DS.touch - 4)
                    .background(on ? AnyShapeStyle(DS.focus) : AnyShapeStyle(DS.faint), in: RoundedRectangle(cornerRadius: DS.chip, style: .continuous))
                }.buttonStyle(PressDown())
            }
        }
        Text("点亮的才会做；身体侧着、被挡住或没拍全时自动跳过。").font(DS.note).foregroundStyle(DS.soft)
    }

    private var shapeCount: Int { [studio.shapes.slim, studio.shapes.eyes, studio.shapes.waist, studio.shapes.chest, studio.shapes.legs, studio.shapes.light].filter { $0 }.count }
    private func shapeOn(_ k: String) -> Binding<Bool> {
        switch k {
        case "slim": $studio.shapes.slim
        case "eyes": $studio.shapes.eyes
        case "waist": $studio.shapes.waist
        case "chest": $studio.shapes.chest
        case "legs": $studio.shapes.legs
        default: $studio.shapes.light
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(["调色", "美颜", "塑形"].enumerated()), id: \.offset) { i, t in
                let on = tab == i
                Button { withAnimation(DS.pick) { tab = i } } label: {
                    Text(t).font(.system(size: 14, weight: on ? .semibold : .regular)).foregroundStyle(on ? DS.onFocus : DS.ink)
                        .frame(maxWidth: .infinity).frame(height: DS.touch - 6)
                        .background { if on { Capsule().fill(DS.focus).matchedGeometryEffect(id: "tab", in: space) } }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(DS.faint, in: Capsule())
    }

    @ViewBuilder private func fold<C: View>(_ i: Int, _ title: String, _ state: String, @ViewBuilder _ content: () -> C) -> some View {
        Button { withAnimation(DS.pick) { open = open == i ? -1 : i } } label: {
            HStack {
                Text(title).font(DS.section)
                Spacer()
                Text(state).font(DS.label).foregroundStyle(open == i ? DS.soft : DS.focus)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).rotationEffect(.degrees(open == i ? 180 : 0))
                    .foregroundStyle(DS.soft)
            }
            .frame(height: DS.touch).contentShape(Rectangle())
        }.buttonStyle(.plain)
        if open == i { VStack(alignment: .leading, spacing: 12) { content() }.transition(.opacity) }
        Rectangle().fill(DS.line).frame(height: 1)
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var beauty: some View {
        if Self.layout != 1 && Self.layout != 2 { Text("美颜").font(DS.section) }
        if let p = studio.currentPhoto, !p.analysed {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在找人脸，马上就好").font(DS.body) }.foregroundStyle(DS.soft)
        } else if studio.currentPhoto?.faces.isEmpty ?? true {
            Text("这张照片里没有找到人脸，只调色。").font(DS.body).foregroundStyle(DS.soft)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BeautyLevel.allCases) { level in
                    let on = studio.beauty == level
                    Button { withAnimation(DS.pick) { studio.beauty = level } } label: {
                        Text(level.title).font(.system(size: 14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? DS.onFocus : DS.ink)
                            .frame(maxWidth: .infinity).frame(height: DS.touch - 4)
                            .background(on ? AnyShapeStyle(DS.focus) : AnyShapeStyle(DS.faint), in: RoundedRectangle(cornerRadius: DS.chip, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(PressDown())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(studio.beauty.note).font(DS.body).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
            if studio.beauty != .off {
                ToneSlider(low: "弱", high: "强", value: strength, number: { v in "\(Int(((v >= 0 ? 1 + 0.3 * v : 1 + 0.35 * v) * 100).rounded()))%" })
            }
        }
    }

    /// The strength slider as -2 … 2 for ToneSlider: middle = the level as set, ends = 0.3× and 1.6×.
    private var strength: Binding<Double> {
        Binding(get: { let a = studio.beautyAmount; return a >= 1 ? (a - 1) / 0.3 : (a - 1) / 0.35 },
                set: { v in studio.beautyAmount = v >= 0 ? 1 + 0.3 * v : 1 + 0.35 * v })
    }

    @ViewBuilder private var action: some View {
        switch studio.stage {
        case .exporting(let i, let n):
            HStack(spacing: 10) { ProgressView(); Text("正在保存 \(i + 1)/\(n)…").font(DS.body) }.frame(height: 52)
        case .working(let s):
            HStack(spacing: 10) { ProgressView(); Text(s).font(DS.body) }.frame(height: 52)
        default:
            PrimaryButton(title: studio.photos.count > 1 ? "全部存进相册（\(studio.photos.count) 张）" : "存进相册", wide: true) { studio.exportAll() }
            if case .done(let n) = studio.stage {
                Text("已存好 \(n) 张，在相册里能看到。").font(DS.note).foregroundStyle(DS.focus)
            } else {
                Text("原片不会被改动，存进去的是一张新照片。").font(DS.note).foregroundStyle(DS.soft)
            }
        }
    }
}

/// Every look along the bottom, each a small picture of this photo; the chosen one in focus brackets.
struct LookTray: View {
    @EnvironmentObject var studio: Studio
    var height: CGFloat
    @Namespace private var space

    var body: some View {
        GeometryReader { box in
            let n = CGFloat(Look.all.count)
            let width = min(150, max(78, (box.size.width - 36 - 14 * (n - 1)) / n))
            Scrolling(axis: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Look.all) { look in card(look, width) }
                }
                .padding(.horizontal, 18).padding(.top, 14)
                .frame(minWidth: box.size.width)
            }
        }
        .frame(height: height)
        .glass(RoundedRectangle(cornerRadius: DS.tray, style: .continuous))
    }

    private func card(_ look: Look, _ width: CGFloat) -> some View {
        let on = studio.look == look.id
        return Button { withAnimation(DS.pick) { studio.look = look.id } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let c = studio.cards[look.id] { Image(decorative: c, scale: 1).resizable().scaledToFill() }
                    else { DS.faint }
                }
                .frame(width: width, height: height - 64).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(5)
                .overlay { if on { FocusMark().matchedGeometryEffect(id: "look", in: space) } }
                .padding(-5)
                Text(look.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? DS.focus : DS.ink).lineLimit(1).padding(.top, 4)
                Text(look.note).font(DS.note).foregroundStyle(DS.soft).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .opacity(on ? 1 : 0.78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.title).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A stepless slider between two words (-2 … 2, middle = as the look made it), drawn as the Mac app's rows: a thin
/// track, a white knob that turns focus yellow once moved. The words step by one; a double tap goes back to the middle.
struct ToneSlider: View {
    let low: String
    let high: String
    @Binding var value: Double
    var caption: String? = nil       // a small name above the row where the two words alone are not enough
    /// The number shown beside the track (rule for every app, user 2026-11-15: stepless sliders show their value).
    var number: (Double) -> String = { v in let n = Int((v * 50).rounded()); return n == 0 ? "0" : String(format: "%+d", n) }
    @State private var live: Double = 0
    @State private var dragging = false
    @State private var from: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption { Text(caption).font(DS.note).foregroundStyle(DS.soft).padding(.leading, 6).padding(.top, 4) }
            row
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            end(low, -0.1)
            GeometryReader { g in
                let w = g.size.width, knob: CGFloat = 16
                let v = dragging ? live : value
                let at = (CGFloat(v) + 2) / 4 * (w - knob)
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.faint).frame(height: 2).padding(.horizontal, knob / 2)
                    Circle().fill(DS.soft).frame(width: 5, height: 5).offset(x: w / 2 - 2.5)
                    Capsule().fill(DS.focus.opacity(0.8)).frame(width: abs(at + knob / 2 - w / 2), height: 2)
                        .offset(x: min(at + knob / 2, w / 2))
                    Circle().fill(abs(v) < 0.01 ? DS.ink : DS.focus).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3)
                        .scaleEffect(dragging ? 1.25 : 1).animation(.spring(duration: 0.2), value: dragging)
                        .offset(x: at)
                }
                .frame(height: DS.touch).contentShape(Rectangle())
                // the knob moves from where it stands, whatever the finger touched: a tap never changes the value
                .gesture(DragGesture(minimumDistance: 2).onChanged { d in
                    if !dragging { dragging = true; from = value; live = value }
                    var nv = from + Double(d.translation.width / max(w - knob, 1)) * 4
                    nv = min(2, max(-2, nv)); if abs(nv) < 0.08 { nv = 0 }       // within 4 units of 0: snaps to 0
                    live = nv
                    if abs(nv - value) > 0.03 { value = nv }
                }.onEnded { _ in value = live; dragging = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(DS.pick) { value = 0 } })
            }
            .frame(minWidth: 90).frame(height: DS.touch)
            end(high, 0.1)
            // the value, always shown; a tap brings it back to 0 (docs/design/DESIGN.md §7 无级调色滑块)
            Button { withAnimation(DS.pick) { value = 0 } } label: {
                Text(number(dragging ? live : value)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(abs(dragging ? live : value) < 0.01 ? DS.soft : DS.focus)
                    .frame(width: 38, height: DS.touch, alignment: .trailing).contentShape(Rectangle())
                    .contentTransition(.numericText())
            }.buttonStyle(.plain).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(low)\(high)").accessibilityValue(number(value))
        .accessibilityAdjustableAction { d in value = d == .increment ? min(2, value + 0.1) : max(-2, value - 0.1) }
    }

    /// An end word: each press 5 units (0.1), held: keeps going.
    private func end(_ title: String, _ by: Double) -> some View {
        RepeatButton(action: { value = min(2, max(-2, ((value + by) * 20).rounded() / 20)) }) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.ink)
                .frame(width: DS.touch - 10, height: DS.touch).contentShape(Rectangle())
        }
    }
}

/// A button that fires once on press and then repeatedly while held (after 0.4 s, every 0.08 s).
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var timer: Timer?
    @State private var pressed = false
    var body: some View {
        label()
            .opacity(pressed ? 0.6 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true; action()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        Task { @MainActor in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in Task { @MainActor in action() } }
                        }
                    }
                }
                .onEnded { _ in pressed = false; timer?.invalidate(); timer = nil })
    }
}

/// 白平衡 / 阴影 / 高光: one colour wheel at a time under a three-part bar (docs/design/DESIGN.md §7 色盘).
struct WheelPicker: View {
    @Binding var tweak: Tweak
    @State private var which = 0
    @Namespace private var space

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(["白平衡", "阴影", "高光"].enumerated()), id: \.offset) { i, t in
                    let on = which == i
                    let moved = i == 0 ? (tweak.warm != 0 || tweak.tint != 0) : i == 1 ? tweak.shadowMoved : tweak.highlightMoved
                    Button { withAnimation(DS.pick) { which = i } } label: {
                        HStack(spacing: 4) {
                            Text(t).font(.system(size: 13, weight: on ? .semibold : .regular))
                            if moved { Circle().fill(on ? DS.onFocus : DS.focus).frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(on ? DS.onFocus : DS.ink)
                        .frame(maxWidth: .infinity).frame(height: DS.touch - 8)
                        .background { if on { Capsule().fill(DS.focus).matchedGeometryEffect(id: "wheel", in: space) } }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(3).background(DS.faint, in: Capsule())
            switch which {
            case 0:
                ColorWheel(kind: .balance, x: $tweak.warm, y: $tweak.tint)
            case 1:
                ColorWheel(kind: .grade, x: hueSat(\.shadowHue, \.shadowSat).x, y: hueSat(\.shadowHue, \.shadowSat).y,
                           start: point(tweak.shadowBaseHue, tweak.shadowBaseSat))
            default:
                ColorWheel(kind: .grade, x: hueSat(\.highlightHue, \.highlightSat).x, y: hueSat(\.highlightHue, \.highlightSat).y,
                           start: point(tweak.highlightBaseHue, tweak.highlightBaseSat))
            }
        }
    }

    private func point(_ h: Double, _ k: Double) -> CGPoint { CGPoint(x: cos(h * .pi / 180) * k * 2, y: sin(h * .pi / 180) * k * 2) }

    /// Hue (degrees) and strength (0…1) seen as a point in the wheel (-2…2 both ways, radius 2 = strength 1).
    private func hueSat(_ h: WritableKeyPath<Tweak, Double>, _ s: WritableKeyPath<Tweak, Double>) -> (x: Binding<Double>, y: Binding<Double>) {
        let x = Binding<Double>(get: { cos(tweak[keyPath: h] * .pi / 180) * tweak[keyPath: s] * 2 },
                                set: { nx in let y = sin(tweak[keyPath: h] * .pi / 180) * tweak[keyPath: s] * 2; set(nx, y, h, s) })
        let y = Binding<Double>(get: { sin(tweak[keyPath: h] * .pi / 180) * tweak[keyPath: s] * 2 },
                                set: { ny in let x = cos(tweak[keyPath: h] * .pi / 180) * tweak[keyPath: s] * 2; set(x, ny, h, s) })
        return (x, y)
    }
    private func set(_ x: Double, _ y: Double, _ h: WritableKeyPath<Tweak, Double>, _ s: WritableKeyPath<Tweak, Double>) {
        let r = min(2, hypot(x, y))
        tweak[keyPath: s] = r / 2
        if r > 0.001 { tweak[keyPath: h] = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
    }
}

/// A round colour wheel: a dot dragged from where it stands (never jumping to the finger), held inside the circle,
/// snapping to the centre within 4 units; double tap or the numbers reset it. `x`, `y`: -2…2.
struct ColorWheel: View {
    enum Kind { case balance, grade }
    let kind: Kind
    @Binding var x: Double
    @Binding var y: Double
    var start: CGPoint = .zero          // where the dot starts and returns to (a look's own split toning)
    @State private var from = CGPoint.zero
    @State private var dragging = false
    private let size: CGFloat = 170

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                face
                Path { p in p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                           p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size)) }
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                Circle().fill(Color.white.opacity(0.7)).frame(width: 5, height: 5)
                let pt = CGPoint(x: size / 2 + CGFloat(x) / 2 * size / 2, y: size / 2 - CGFloat(y) / 2 * size / 2)
                let off = hypot(x, y) > 0.01, moved = hypot(x - Double(start.x), y - Double(start.y)) > 0.01
                if off {
                    Path { p in p.move(to: CGPoint(x: size / 2, y: size / 2)); p.addLine(to: pt) }.stroke(moved ? DS.focus : Color.white.opacity(0.35), lineWidth: 2)
                }
                Circle().fill(moved ? DS.focus : DS.ink).frame(width: 18, height: 18).shadow(color: .black.opacity(0.4), radius: 3)
                    .scaleEffect(dragging ? 1.2 : 1).position(pt)
                if kind == .balance {
                    Group {
                        Text("暖").position(x: size - 12, y: size / 2 - 12); Text("冷").position(x: 12, y: size / 2 - 12)
                        Text("粉").position(x: size / 2 + 12, y: 12); Text("绿").position(x: size / 2 + 12, y: size - 12)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -12))
            .gesture(DragGesture(minimumDistance: 2).onChanged { d in
                if !dragging { dragging = true; from = CGPoint(x: x, y: y) }
                var nx = Double(from.x) + Double(d.translation.width / (size / 2)) * 2
                var ny = Double(from.y) - Double(d.translation.height / (size / 2)) * 2
                let r = hypot(nx, ny)
                if r > 2 { nx *= 2 / r; ny *= 2 / r }                        // held on the rim
                if hypot(nx, ny) < 0.08 { nx = 0; ny = 0 }                     // within 4 units: the centre
                x = nx; y = ny
            }.onEnded { _ in dragging = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(DS.pick) { x = Double(start.x); y = Double(start.y) } })
            Button { withAnimation(DS.pick) { x = Double(start.x); y = Double(start.y) } } label: {
                Text(numbers).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(hypot(x - Double(start.x), y - Double(start.y)) > 0.01 ? DS.focus : DS.soft).frame(height: 28)
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore).accessibilityLabel(kind == .balance ? "白平衡" : "分区调色").accessibilityValue(numbers)
    }

    private var numbers: String {
        let n = { (v: Double) -> String in let k = Int((v * 50).rounded()); return k == 0 ? "0" : String(format: "%+d", k) }
        if kind == .balance { return "冷暖 \(n(x))   绿粉 \(n(y))" }
        let r = hypot(x, y), hue = r > 0.001 ? Int(((atan2(y, x) * 180 / .pi) + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360 : 0
        return "色相 \(hue)°   浓度 \(Int((r / 2 * 100).rounded()))"
    }

    /// Balance: warm right, cool left, pink up, green down. Grade: a hue circle, red right, counter-clockwise.
    /// Colours mixed 40 % towards grey, so the wheel does not compete with the photo.
    @ViewBuilder private var face: some View {
        if kind == .balance {
            ZStack {
                LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 0.75), Color(red: 0.6, green: 0.6, blue: 0.6), Color(red: 0.85, green: 0.62, blue: 0.40)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [Color(red: 0.82, green: 0.52, blue: 0.70).opacity(0.75), .clear, Color(red: 0.48, green: 0.72, blue: 0.48).opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(Circle()).opacity(0.85)
        } else {
            ZStack {
                // on screen angles run clockwise: red at the right, then (visually anticlockwise) yellow, green, cyan…
                AngularGradient(colors: [0, 300, 240, 180, 120, 60, 0].map { h in
                    Color(hue: Double(h) / 360, saturation: 0.6, brightness: 0.85) }, center: .center, startAngle: .degrees(0), endAngle: .degrees(360))
                RadialGradient(colors: [Color(white: 0.6), Color(white: 0.6).opacity(0)], center: .center, startRadius: 0, endRadius: size / 2)
            }
            .clipShape(Circle()).opacity(0.85)
        }
    }
}

/// 设置: version, automatic update check, model updates (moved here from the panel, user 2026-11-15).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("一键修图").font(.system(size: 17, weight: .semibold))
                        Text("版本 \(UpdateNotice.appVersion) · 修图模型 \(String(ModelStore.installedVersion.prefix(8)))")
                            .font(.system(size: 12)).foregroundStyle(Palette.soft)
                    }
                    Divider().overlay(Palette.line)
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { RightsCenter.shared.openCard() }
                    } label: {
                        Label(RL.rightsMenu, systemImage: "hand.raised").font(.system(size: 14))
                    }.foregroundStyle(Palette.glow)
                    Button { UserDefaults.standard.set(false, forKey: "onboarded"); dismiss() } label: {
                        Label("再看一遍使用教程", systemImage: "questionmark.circle").font(.system(size: 14))
                    }.foregroundStyle(Palette.glow)
                    Divider().overlay(Palette.line)
                    Text("更新").font(.system(size: 15, weight: .semibold))
                    UpdateRow()
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading)
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .background(Palette.bg)
        }
        .preferredColorScheme(.dark)
    }
}

/// A scroll view, except in snapshot tests (ImageRenderer draws nothing inside a ScrollView).
struct Scrolling<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder let content: Content
    var body: some View {
        if SelfTest.flat { if axis == .vertical { content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else { content } }
        else { ScrollView(axis, showsIndicators: false) { content } }
    }
}

/// The thin progress bar of the background work on imported photos: a hairline that fills in focus yellow, the
/// count beside it (user's choice of the four shapes, 2026-11-15).
struct ProgressLine: View {
    let done: Int, total: Int
    var text: String? = nil           // "正在加载照片 3 / 30" (Studio.updateProgress); nil = the percentage
    var compact = false               // narrow screens: the words only
    var body: some View {
        let f = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        HStack(spacing: 10) {
            if !compact { GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.faint)
                    Capsule().fill(DS.focus).frame(width: max(4, g.size.width * f))
                        .shadow(color: DS.focus.opacity(0.6), radius: 4)
                        .animation(.smooth(duration: 0.5), value: f)
                }
            }
            .frame(width: 160, height: 3) }
            Text(text ?? "正在准备 \(Int((f * 100).rounded()))%").font(DS.label).foregroundStyle(DS.soft).monospacedDigit()
                .lineLimit(1).fixedSize()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16).frame(height: DS.touch)
        .glass(Capsule())
        .transition(.opacity)
    }
}

/// While 联机拍摄 is receiving: a small glass capsule in the top row; a tap opens the page (stop is there).
struct TetherBadge: View {
    @ObservedObject var tether = Tether.shared
    let open: () -> Void
    var body: some View {
        if tether.on {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(DS.focus).frame(width: 8, height: 8)
                    Text(tether.received == 0 ? "联机中" : "联机中 · \(tether.received) 张").font(.system(size: 14, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 16).frame(height: DS.touch).glass(Capsule(), interactive: true)
            }.buttonStyle(.plain).foregroundStyle(DS.ink)
        }
    }
}
