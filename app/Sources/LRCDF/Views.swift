import SwiftUI

enum Palette {
    static let ink = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let panel = Color(red: 0.095, green: 0.095, blue: 0.11)
    static let line = Color.white.opacity(0.08)
    static let soft = Color.white.opacity(0.55)
    static let glowA = Color(red: 1.0, green: 0.50, blue: 0.47)
    static let glowB = Color(red: 1.0, green: 0.70, blue: 0.44)
    static let glow = LinearGradient(colors: [glowA, glowB], startPoint: .leading, endPoint: .trailing)
}

struct RootView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            switch studio.stage {
            case .waiting: WaitingView()
            case .preparing: PreparingView()
            case .failed(let why): FailedView(message: why)
            case .reviewing: ReviewView()
            case .choosing, .working, .paused, .finished: StudioView()
            }
        }
    }
}

// MARK: - Before anything is chosen

struct WaitingView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.glow)
            Text("LRCDF 一键修图").font(.system(size: 30, weight: .semibold))
            VStack(spacing: 10) {
                StepRow(number: 1, text: "在 Lightroom 里选中要修的照片")
                StepRow(number: 2, text: "菜单 图库 → 增效工具额外信息 → 开始一键修图…")
                StepRow(number: 3, text: "回到这里挑一个喜欢的效果")
            }
            .padding(.top, 6)
            if !studio.lightroomOpen {
                Label("还没有连上 Lightroom Classic，请先打开它", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Palette.glowB)
                    .padding(.top, 8)
                Button("打开 Lightroom") { studio.backToLightroom() }
                    .buttonStyle(GhostButton())
            }
            LastRunCard().padding(.top, 10)
        }
        .padding(40)
    }
}

/// What is left over from last time: a run to carry on with, or one that can still be undone.
struct LastRunCard: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        if let run = studio.run, !run.undone {
            VStack(spacing: 10) {
                if !run.finished {
                    Text("上次有 \(run.remaining) 张还没修完（已完成 \(run.done.count) 张）")
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        Button("继续修完") { studio.work() }.buttonStyle(GhostButton())
                        Button("不修了") { studio.stopRun() }.buttonStyle(GhostButton())
                    }
                } else if !run.done.isEmpty {
                    Text("上次修了 \(run.done.count) 张").font(.system(size: 13)).foregroundStyle(Palette.soft)
                    HStack(spacing: 10) {
                        Button("查看成片") { studio.startReview() }.buttonStyle(GhostButton())
                        Button("撤销上次修图") { studio.undoRun() }.buttonStyle(GhostButton())
                    }
                }
                if let notice = studio.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Palette.soft)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
            .disabled(!studio.lightroomOpen)
        } else if let notice = studio.notice {
            Text(notice).font(.system(size: 12)).foregroundStyle(Palette.soft)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.1)))
            Text(text).font(.system(size: 15)).foregroundStyle(Palette.soft)
            Spacer()
        }
        .frame(width: 380)
    }
}

struct PreparingView: View {
    @EnvironmentObject var studio: Studio
    @State private var turning = false

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(Palette.glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                .onAppear { turning = true }
            Text("正在用你的照片试每一种效果").font(.system(size: 20, weight: .semibold))
            Text(studio.session.map { "\($0.name) · 大约 20 秒，同一张照片下次直接打开" } ?? "")
                .font(.callout).foregroundStyle(Palette.soft)
        }
    }
}

struct FailedView: View {
    @EnvironmentObject var studio: Studio
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(Palette.glowB)
            Text("没有完成").font(.system(size: 22, weight: .semibold))
            Text(message).font(.callout).foregroundStyle(Palette.soft)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 12) {
                if let run = studio.run, !run.finished {
                    Button("继续") { studio.work() }.buttonStyle(GhostButton())
                }
                Button("回到 Lightroom") { studio.backToLightroom() }.buttonStyle(GhostButton())
                if !studio.looks.isEmpty {
                    Button("返回") { studio.again() }.buttonStyle(GhostButton())
                }
            }
        }
        .padding(40)
    }
}

// MARK: - The studio: picture, looks, retouching

struct StudioView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let choosing = studio.stage == .choosing
        HStack(spacing: 0) {
            if studio.count > 1 {
                PhotoStrip(ids: studio.session?.ids ?? [], hint: "点一张看它的效果\n所选设置用于全部")
                    .frame(width: 104)
                    .disabled(!choosing)
                    .opacity(choosing ? 1 : 0.35)
            }
            VStack(spacing: 0) {
                ZStack {
                    if let before = studio.original, let chosen = studio.chosen, let after = studio.after {
                        VStack(spacing: 12) {
                            CompareView(before: before.image, after: after, title: chosen.title,
                                        plain: chosen.id == "none" && !studio.beautyShown,
                                        retouched: studio.beautyShown, pending: !studio.pictureExact)
                                .id(studio.photo)
                            ZoomBar()
                        }
                        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 12)
                        .blur(radius: choosing && studio.loading == nil ? 0 : 14)
                        .opacity(choosing && studio.loading == nil ? 1 : 0.45)
                    }
                    if studio.loading != nil, choosing { LoadingPhotoOverlay() }
                    if studio.stage == .working { WorkingOverlay() }
                    if studio.stage == .paused { PausedOverlay() }
                    if studio.stage == .finished { FinishedOverlay() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LookStrip()
                    .disabled(!choosing || studio.loading != nil)
                    .opacity(choosing ? 1 : 0.35)
            }
            Sidebar()
                .frame(width: 300)
                .disabled(!choosing)
                .opacity(choosing ? 1 : 0.35)
        }
    }
}

/// The photos, down the left side. Click one to look at it.
struct PhotoStrip: View {
    @EnvironmentObject var studio: Studio
    let ids: [Int]
    let hint: String

    var body: some View {
        VStack(spacing: 0) {
            Text("\(ids.count) 张")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.soft)
                .padding(.top, 46).padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        PhotoThumb(image: studio.thumbs[id], selected: studio.photo == id, loading: studio.loading == id,
                                   flags: studio.flags[id] ?? [])
                            .onTapGesture { studio.show(id) }
                    }
                }
                .padding(.vertical, 4)
            }
            Text(hint)
                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.35))
                .multilineTextAlignment(.center).padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
}

struct PhotoThumb: View {
    let image: NSImage?
    let selected: Bool
    let loading: Bool
    let flags: [String]

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.06))
                }
                if loading { ProgressView().controlSize(.small) }
            }
            .frame(width: 76, height: 76)
            if !flags.isEmpty {
                Text(flags.map { ["eyes": "闭眼", "blur": "虚焦", "over": "过曝", "dup": "重复"][$0] ?? $0 }.joined(separator: " "))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Palette.glowB))
                    .padding(.bottom, 4)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(selected ? AnyShapeStyle(Palette.glow) : AnyShapeStyle(Palette.line), lineWidth: selected ? 2.5 : 1))
        .opacity(selected || loading ? 1 : 0.7)
        .contentShape(Rectangle())
    }
}

struct LoadingPhotoOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在用这张照片试每一种效果").font(.system(size: 17, weight: .semibold))
            Text("大约 20 秒，看过的照片下次直接打开").font(.callout).foregroundStyle(Palette.soft)
        }
        .transition(.opacity)
    }
}

/// Under the picture: zoom out, how far in, zoom in, the whole picture, and a jump from face to face.
struct ZoomBar: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                BarButton(symbol: "minus") { withAnimation(.easeOut(duration: 0.2)) { studio.zoom(by: 1 / 1.5) } }
                    .disabled(studio.zoom <= 1)
                Text(studio.zoom <= 1.01 ? "适合窗口" : String(format: "%.1f×", studio.zoom))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(width: 62)
                    .contentShape(Rectangle())
                    .onTapGesture { studio.fit() }
                BarButton(symbol: "plus") { withAnimation(.easeOut(duration: 0.2)) { studio.zoom(by: 1.5) } }
                    .disabled(studio.zoom >= 8)
            }
            .padding(.horizontal, 4).frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            if !studio.faces.isEmpty {
                Button(action: studio.nextFace) {
                    Label(studio.face == nil ? "放大看脸" : (studio.face! + 1 < min(studio.faces.count, 4) ? "下一张脸" : "看整张"),
                          systemImage: "face.smiling")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Text("滚轮或双指捏合缩放 · 放大后拖动照片移动 · 双击放大/还原")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.3)).lineLimit(1)
        }
    }
}

struct BarButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Catches the mouse wheel, two-finger scrolling and pinching over a view (SwiftUI has no gesture for the first two).
struct ScrollCatcher: NSViewRepresentable {
    /// (wheel steps, scrolled by, pinched by, where: 0…1 across the view from the top left)
    let handler: (CGFloat, CGSize, CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(handler: handler) }
    func updateNSView(_ view: Catcher, context: Context) { view.handler = handler }

    final class Catcher: NSView {
        var handler: (CGFloat, CGSize, CGFloat, CGPoint) -> Void
        private var monitor: Any?

        init(handler: @escaping (CGFloat, CGSize, CGFloat, CGPoint) -> Void) {
            self.handler = handler
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.width > 1 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let place = CGPoint(x: point.x / self.bounds.width, y: 1 - point.y / self.bounds.height)
                if event.type == .magnify {
                    self.handler(0, .zero, event.magnification, place)
                } else if event.hasPreciseScrollingDeltas {      // trackpad: two fingers move the picture
                    self.handler(0, CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), 0, place)
                } else {                                         // mouse wheel: zoom
                    self.handler(event.scrollingDeltaY, .zero, 0, place)
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// The photo with a divider that can be dragged: the original on the left, the result on the right.
/// It can be zoomed (wheel, pinch, buttons, double click) and, once zoomed, moved by dragging.
struct CompareView: View {
    @EnvironmentObject var studio: Studio
    let before: NSImage
    let after: NSImage
    let title: String
    let plain: Bool          // nothing changes the picture: no divider
    let retouched: Bool
    let pending: Bool
    @State private var split: CGFloat = 0.5
    @State private var dragging: Drag?
    private enum Drag { case divider, picture(CGPoint) }

    var body: some View {
        let size = before.size
        GeometryReader { box in
            let w = box.size.width, h = box.size.height
            let zoom = studio.zoom
            let shift = CGSize(width: (0.5 - studio.centre.x) * w * zoom, height: (0.5 - studio.centre.y) * h * zoom)
            ZStack(alignment: .topLeading) {
                Image(nsImage: after).resizable().interpolation(.high).frame(width: w, height: h)
                    .scaleEffect(zoom).offset(shift)
                if !plain {
                    Image(nsImage: before).resizable().interpolation(.high).frame(width: w, height: h)
                        .scaleEffect(zoom).offset(shift)
                        .mask(alignment: .leading) { Rectangle().frame(width: w * split) }
                    Rectangle().fill(.white).frame(width: 1.5, height: h)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: w * split - 0.75)
                    Circle().fill(.white).frame(width: 34, height: 34)
                        .overlay(Image(systemName: "chevron.left.chevron.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.75)))
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                        .offset(x: w * split - 17, y: h / 2 - 17)
                    Tag(text: "原片").padding(14).opacity(split > 0.14 ? 1 : 0)
                    HStack(spacing: 6) {
                        if pending { ProgressView().controlSize(.mini) }
                        Text(pending ? "\(title) · 美颜预览生成中" : (retouched ? "\(title) + 美颜" : title))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(14)
                    .frame(width: w, alignment: .topTrailing).opacity(split < 0.86 ? 1 : 0)
                } else {
                    Tag(text: "原片").padding(14)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
            .contentShape(Rectangle())
            .background(ScrollCatcher { wheel, scrolled, pinched, place in
                if pinched != 0 {
                    studio.zoom(by: 1 + pinched, at: place)
                } else if wheel != 0 {
                    studio.zoom(by: wheel > 0 ? 1.18 : 1 / 1.18, at: place)
                } else if studio.zoom > 1 {
                    studio.look(at: CGPoint(x: studio.centre.x - scrolled.width / (w * studio.zoom),
                                            y: studio.centre.y - scrolled.height / (h * studio.zoom)))
                }
            })
            .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                if dragging == nil {
                    // the divider is taken by its line; anywhere else moves a zoomed picture
                    let onLine = abs(drag.startLocation.x - w * split) < 26
                    dragging = !plain && (onLine || studio.zoom <= 1.01) ? .divider : .picture(studio.centre)
                }
                switch dragging {
                case .divider:
                    split = min(1, max(0, drag.location.x / max(w, 1)))
                case .picture(let from):
                    studio.look(at: CGPoint(x: from.x - drag.translation.width / (w * studio.zoom),
                                            y: from.y - drag.translation.height / (h * studio.zoom)))
                case nil: break
                }
            }.onEnded { _ in dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                withAnimation(.spring(duration: 0.4)) {
                    if studio.zoom > 1.01 { studio.zoom = 1; studio.centre = CGPoint(x: 0.5, y: 0.5); studio.face = nil }
                    else { studio.zoom(by: 3, at: CGPoint(x: tap.location.x / max(w, 1), y: tap.location.y / max(h, 1))) }
                }
            })
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct LookStrip: View {
    @EnvironmentObject var studio: Studio
    @State private var saving = false

    var body: some View {
        GeometryReader { box in
            // every look is visible at once: the cards share the width, nothing hides behind a scroll
            let n = CGFloat(studio.looks.count + 1)
            let width = min(170, max(70, (box.size.width - 48 - 12 * (n - 1)) / n))
            HStack(spacing: 12) {
                ForEach(studio.looks) { look in
                    LookCard(look: look, selected: studio.look == look.id, width: width)
                        .id("\(studio.photo)-\(look.id)")
                        .onTapGesture { withAnimation(.spring(duration: 0.3)) { studio.look = look.id } }
                }
                AddLookCard(width: width).onTapGesture { studio.styleError = nil; saving = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 176)
        .background(Palette.panel.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .sheet(isPresented: $saving) { SaveStyleSheet(showing: $saving).environmentObject(studio) }
    }
}

struct LookCard: View {
    @EnvironmentObject var studio: Studio
    let look: Look
    let selected: Bool
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(nsImage: look.image)
                .resizable().scaledToFill()
                .frame(width: width, height: min(104, width * 0.66))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? AnyShapeStyle(Palette.glow) : AnyShapeStyle(Palette.line), lineWidth: selected ? 2.5 : 1))
                .overlay(alignment: .topTrailing) {
                    if look.mine && hovering {
                        Button { studio.deleteStyle(look.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20).background(Circle().fill(.black.opacity(0.65)))
                        }
                        .buttonStyle(.plain).padding(5).help("删除这个风格")
                    }
                }
                .scaleEffect(hovering && !selected ? 1.03 : 1)
            Text(look.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Palette.soft).lineLimit(1)
            Text(look.note)
                .font(.system(size: 11)).foregroundStyle(look.mine ? Palette.glowB.opacity(0.8) : Color.white.opacity(0.35)).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

struct AddLookCard: View {
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(Color.white.opacity(hovering ? 0.5 : 0.22))
                .frame(width: width, height: min(104, width * 0.66))
                .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.soft))
            Text("存为我的风格").font(.system(size: 13)).foregroundStyle(Palette.soft).lineLimit(1)
            Text("照你调好的来").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.35)).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct SaveStyleSheet: View {
    @EnvironmentObject var studio: Studio
    @Binding var showing: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("存为我的风格").font(.system(size: 18, weight: .semibold))
            Text("先在 Lightroom 里把左边选中的这张照片调到你满意的样子，再回到这里点“保存”。\n之后它会成为一张新的效果卡片，对别的照片也会按你的调法来，并且照样根据每张照片自动调整曝光和白平衡。\n这次带过来的照片里，其他已经调过的也会一起用来学习：调过的越多，学得越准（6 张以上最好）。")
                .font(.system(size: 12)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
            TextField("给它起个名字，例如：我的日系", text: $name)
                .textFieldStyle(.roundedBorder)
            if let error = studio.styleError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.glowB).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if studio.savingStyle { ProgressView().controlSize(.small); Text("正在学习你的调法…").font(.system(size: 12)).foregroundStyle(Palette.soft) }
                Spacer()
                Button("取消") { showing = false }.buttonStyle(GhostButton()).disabled(studio.savingStyle)
                Button { studio.saveStyle(named: name) { ok in if ok { showing = false } } } label: {
                    Text("保存").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).frame(height: 40)
                }
                .buttonStyle(GlowButton()).disabled(studio.savingStyle)
            }
        }
        .padding(24).frame(width: 440)
        .background(Palette.panel)
        .preferredColorScheme(.dark)
    }
}

struct Sidebar: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("一键修图").font(.system(size: 22, weight: .semibold))
                Text(studio.count > 1 ? "共 \(studio.count) 张照片，设置会用于全部" : (studio.session?.name ?? ""))
                    .font(.system(size: 12)).foregroundStyle(Palette.soft).lineLimit(1)
            }
            .padding(.top, 44)

            Heading(number: "1", title: "效果").padding(.top, 22)
            Text(studio.chosen.map { $0.id == "none" ? "保持原片的颜色" : "\($0.title) · \($0.note)" } ?? "")
                .font(.system(size: 13)).foregroundStyle(Palette.soft).lineLimit(1)
                .padding(.top, 8)
            VStack(spacing: 6) {
                TweakRow(low: "暗", high: "亮", value: $studio.tweak.bright)
                TweakRow(low: "冷", high: "暖", value: $studio.tweak.warm)
                TweakRow(low: "淡", high: "浓", value: $studio.tweak.rich)
            }
            .padding(.top, 10)
            .disabled(studio.look == "none").opacity(studio.look == "none" ? 0.3 : 1)

            Heading(number: "2", title: "美颜").padding(.top, 22)
            HStack(spacing: 6) {
                ForEach(BeautyLevel.allCases) { level in
                    LevelPill(level: level, selected: studio.level == level)
                        .onTapGesture { withAnimation(.spring(duration: 0.25)) { studio.level = level } }
                }
            }
            .padding(.top, 10)
            Text(studio.level.note).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4)).padding(.top, 7)
            if studio.people.count > 1 && studio.level != .off {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(studio.people) { person in PersonChip(person: person) }
                }
                .padding(.top, 10)
                .help("每个人可以单独设置：点头像，在 跟随、轻、自然、精致、不修 之间切换。跟随 = 用上面的整体档位。男士和小孩默认是 轻；你改过的人，下次会记住。")
            }
            HStack(spacing: 6) {
                ForEach([("slim", "瘦脸"), ("bigeyes", "大眼"), ("waist", "收腰"), ("chest", "丰胸"), ("legs", "长腿"), ("light", "匀光")], id: \.0) { key, title in
                    let on = studio.shapes.contains(key)
                    Text(title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.black.opacity(0.85) : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? AnyShapeStyle(Palette.glow) : AnyShapeStyle(Color.white.opacity(0.06))))
                        .contentShape(Rectangle())
                        .onTapGesture { if on { studio.shapes.remove(key) } else { studio.shapes.insert(key) } }
                }
            }
            .disabled(studio.level == .off).opacity(studio.level == .off ? 0.35 : 1)
            .padding(.top, 10)
            .help("塑形：点亮的才会做。身体侧着、被手挡住、或腿没拍全时，对应的那一项会自动跳过。\n匀光：把侧光造成的一边亮一边暗匀开一些，只动明暗，不动皮肤纹理；鼻影、帽檐这类有边缘的影子不会去掉。")
            Toggle(isOn: $studio.best) { Text("保留最大画质").font(.system(size: 13)) }
                .toggleStyle(.switch).tint(Palette.glowA).controlSize(.small)
                .disabled(studio.level == .off).opacity(studio.level == .off ? 0.35 : 1)
                .padding(.top, 8)
                .help("成片存成 16 位广色域（ProPhoto RGB），适合还要继续精修或大幅输出；每张约 300MB，是平时的三倍多。关闭时是 8 位 sRGB，适合直接交付。")

            Heading(number: "3", title: "降噪").padding(.top, 22)
            Toggle(isOn: $studio.denoise) { Text("AI 降噪").font(.system(size: 13)) }
                .toggleStyle(.switch).tint(Palette.glowA).controlSize(.small)
                .padding(.top, 10)
            Text(studio.noisy
                 ? "这组照片感光度较高（ISO \(studio.session?.iso ?? 0)），建议打开。每张多花约 10 秒。"
                 : "夜景、高感光的照片建议打开。每张多花约 10 秒。")
                .font(.system(size: 11))
                .foregroundStyle(studio.noisy && !studio.denoise ? Palette.glowB : Color.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 7)

            Spacer(minLength: 14)

            if !studio.flagged.isEmpty {
                Toggle(isOn: $studio.skipFlagged) {
                    Text("跳过 \(studio.flagged.count) 张有问题的（闭眼、虚焦、过曝、重复）").font(.system(size: 12))
                }
                .toggleStyle(.checkbox).padding(.bottom, 10)
            }
            Button(action: studio.retouch) {
                Text(studio.targets.count > 1 ? "修好这 \(studio.targets.count) 张" : "修好这张")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
            }
            .buttonStyle(GlowButton())
            .disabled(studio.nothingToDo)
            .opacity(studio.nothingToDo ? 0.4 : 1)
            Text("原片不会被改动，修完可以一键撤销。")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.35))
                .padding(.top, 10).padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
}

struct Heading: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.glow))
            Text(title).font(.system(size: 13, weight: .semibold)).kerning(1)
        }
    }
}

/// One nudge: a word at each end, five steps between, the middle one being "as the look is".
struct TweakRow: View {
    let low: String
    let high: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 8) {
            Button { if value > -2 { value -= 1 } } label: {
                Text(low).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            HStack(spacing: 5) {
                ForEach(-2...2, id: \.self) { step in
                    Capsule()
                        .fill(step == value ? AnyShapeStyle(Palette.glow) : AnyShapeStyle(Color.white.opacity(step == 0 ? 0.28 : 0.12)))
                        .frame(height: step == value ? 6 : 4)
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { value = step }
                }
            }
            .frame(maxWidth: .infinity)
            Button { if value < 2 { value += 1 } } label: {
                Text(high).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
    }
}

/// One person of the shoot: their face, and under it what was chosen for them (nothing = like everyone else).
struct PersonChip: View {
    @EnvironmentObject var studio: Studio
    let person: Person
    static let names = ["follow": "跟随", "light": "轻", "natural": "自然", "refined": "精致", "off": "不修"]

    var body: some View {
        let chosen = studio.choices[person.id] ?? "follow"
        let choice: String? = chosen == "follow" ? nil : chosen
        VStack(spacing: 3) {
            Image(nsImage: person.image).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(Circle())
                .overlay(Circle().stroke(choice == nil ? Color.white.opacity(0.15) : Palette.glowA, lineWidth: choice == nil ? 1 : 2))
                .opacity(choice == "off" ? 0.45 : 1)
            Text(choice.flatMap { Self.names[$0] } ?? "跟随").font(.system(size: 10))
                .foregroundStyle(choice == nil ? Color.white.opacity(0.35) : Palette.glowA)
        }
        .frame(width: 36)
        .contentShape(Rectangle())
        .onTapGesture {      // each click: like everyone else -> natural -> refined -> left alone -> ...
            let order = ["follow", "light", "natural", "refined", "off"]
            let next = order[((order.firstIndex(of: chosen) ?? 0) + 1) % order.count]
            withAnimation(.spring(duration: 0.2)) { studio.choose(next, for: person) }
        }
    }
}

struct LevelPill: View {
    let level: BeautyLevel
    let selected: Bool

    var body: some View {
        Text(level.title)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white.opacity(0.8))
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Palette.glow) : AnyShapeStyle(Color.white.opacity(0.06))))
            .contentShape(Rectangle())
    }
}

// MARK: - While Lightroom works, and afterwards

struct WorkingOverlay: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle().trim(from: 0, to: max(0.02, studio.fraction))
                    .stroke(Palette.glow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(studio.fraction * 100))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 96, height: 96)
            if let run = studio.run {
                Text(run.ids.count > 1 ? "正在修 \(run.ids.count) 张照片" : "正在修这张照片")
                    .font(.system(size: 19, weight: .semibold))
                Text(run.level != "off" && run.ids.count > 1 ? "已完成 \(run.done.count) / \(run.ids.count) · \(studio.caption)" : studio.caption)
                    .font(.callout).foregroundStyle(Palette.soft)
                if run.ids.count > 3 {
                    Button(studio.pauseAsked ? "做完手上这几张就暂停…" : "暂停") { studio.pauseAsked = true }
                        .buttonStyle(GhostButton()).disabled(studio.pauseAsked).padding(.top, 4)
                }
            }
        }
        .transition(.opacity)
    }
}

struct PausedOverlay: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle").font(.system(size: 56, weight: .light)).foregroundStyle(Palette.glow)
            Text("已暂停").font(.system(size: 22, weight: .semibold))
            if let run = studio.run {
                Text("已完成 \(run.done.count) 张，还剩 \(run.remaining) 张。关掉程序也没关系，下次打开可以接着修。")
                    .font(.callout).foregroundStyle(Palette.soft).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button(action: studio.work) {
                    Text("继续").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 26).frame(height: 40)
                }
                .buttonStyle(GlowButton())
                Button("到此为止") { studio.stopRun() }.buttonStyle(GhostButton())
            }
        }
        .transition(.opacity)
    }
}

struct FinishedOverlay: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: studio.run?.undone == true ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .font(.system(size: 60, weight: .light)).foregroundStyle(Palette.glow)
            if let run = studio.run {
                Text(run.undone ? "已撤销" : (run.done.count > 1 ? "\(run.done.count) 张已修好" : "修好了"))
                    .font(.system(size: 24, weight: .semibold))
                if !run.undone {
                    Text(run.created.isEmpty ? "调色已经写进 Lightroom。" : "成片已经在 Lightroom 里，叠在原片上方。")
                        .font(.callout).foregroundStyle(Palette.soft)
                }
                if !run.failed.isEmpty && !run.undone {
                    HStack(spacing: 10) {
                        Text("有 \(run.failed.count) 张没有成功").font(.callout).foregroundStyle(Palette.glowB)
                        Button("再试这 \(run.failed.count) 张") { studio.retryFailed() }.buttonStyle(GhostButton())
                    }
                }
                if let notice = studio.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Palette.soft)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                HStack(spacing: 10) {
                    if !run.undone {
                        Button(action: studio.startReview) {
                            Text("查看成片").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).frame(height: 40)
                        }
                        .buttonStyle(GlowButton())
                    }
                    Button("回到 Lightroom") { studio.backToLightroom() }.buttonStyle(GhostButton())
                    Button("换个效果再来") { studio.again() }.buttonStyle(GhostButton())
                    if !run.undone {
                        Button("撤销这次修图") { studio.undoRun() }.buttonStyle(GhostButton())
                    }
                }
                .padding(.top, 6)
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// The finished pictures next to how the photos were, one photo at a time.
struct ReviewView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(spacing: 0) {
            PhotoStrip(ids: studio.run?.done ?? [], hint: "点一张看它\n修图前后的样子")
                .frame(width: 104)
            VStack(spacing: 12) {
                ZStack {
                    if let before = studio.befores[studio.photo], let after = studio.results[studio.photo] {
                        CompareView(before: before, after: after, title: "成片", plain: false, retouched: false, pending: false)
                            .id(studio.photo)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("正在取这张成片…").font(.callout).foregroundStyle(Palette.soft)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 12) {
                    ZoomBar()
                    Spacer()
                    Button("撤销这次修图") { studio.undoRun(); studio.leaveReview() }.buttonStyle(GhostButton())
                    Button(action: studio.leaveReview) {
                        Text("看完了").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 24).frame(height: 40)
                    }
                    .buttonStyle(GlowButton())
                }
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 20)
        }
    }
}

struct GlowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.glow))
            .shadow(color: Palette.glowA.opacity(configuration.isPressed ? 0.15 : 0.4), radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 20).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
    }
}
