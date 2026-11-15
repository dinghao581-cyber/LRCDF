import SwiftUI

// The screens. What they are made of — colours, type, glass, buttons, the small controls — is in Design.swift;
// the photo with its divider and gestures is in Compare.swift. The rules are written down in docs/design/DESIGN.md.

struct RootView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        ZStack {
            Room()
            switch studio.stage {
            case .waiting: WaitingView().transition(.opacity)
            case .preparing: PreparingView().transition(.opacity)
            case .failed(let why): FailedView(message: why).transition(.opacity)
            case .reviewing: ReviewView().transition(.opacity)
            case .choosing, .working, .paused, .finished: StudioView().transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

/// The room: black, lit by the photo on screen far out of focus. Glass needs something behind it to be glass, and
/// the only light in a darkroom should be the picture's.
struct Room: View {
    @EnvironmentObject var studio: Studio
    @State private var remembered: NSImage?
    private static var small: [ObjectIdentifier: NSImage] = [:]
    private static var order: [ObjectIdentifier] = []

    private var light: NSImage? {
        if studio.stage == .reviewing { return studio.results[studio.photo] ?? studio.befores[studio.photo] }
        return studio.after ?? studio.thumbs[studio.photo] ?? remembered
    }

    /// A few dozen pixels are all a blur of this size needs, and cost nothing to redraw.
    private static func shrunk(_ image: NSImage) -> NSImage {
        let key = ObjectIdentifier(image)
        if let ready = small[key] { return ready }
        let size = NSSize(width: 96, height: max(1, 96 * image.size.height / max(image.size.width, 1)))
        let made = NSImage(size: size, flipped: false) { rect in image.draw(in: rect); return true }
        let fixed = NSImage(size: size)
        if let rep = made.bestRepresentation(for: NSRect(origin: .zero, size: size), context: nil, hints: nil) { fixed.addRepresentation(rep) }
        small[key] = made; order.append(key)
        if order.count > 16 { small[order.removeFirst()] = nil }
        return made
    }

    var body: some View {
        let image = light
        Color.black.overlay {
            if let image {
                Image(nsImage: Self.shrunk(image)).resizable().interpolation(.high).scaledToFill()
                    .blur(radius: 60, opaque: true).saturation(0.6)
                    .overlay(Color.black.opacity(DS.roomShade))
                    .id(ObjectIdentifier(image)).transition(.opacity)
            }
        }
        .clipped()
        .animation(.smooth(duration: 0.6), value: image.map { ObjectIdentifier($0) })
        .onAppear {
            if let id = studio.run?.done.first { remembered = NSImage(contentsOf: Bridge.before.appendingPathComponent("\(id).jpg")) }
        }
    }
}

// MARK: - Before anything is chosen

struct WaitingView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.appTitle).font(DS.display(52)).foregroundStyle(DS.ink)
            VStack(alignment: .leading, spacing: 14) {
                StepRowText(number: 1, text: L.waitingStep1)
                StepRowText(number: 2, text: L.waitingStep2)
                StepRowText(number: 3, text: L.waitingStep3)
            }
            .padding(.top, 28)
            if !studio.lightroomOpen {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { notConnected }
                    VStack(alignment: .leading, spacing: 10) { notConnected }
                }
                .padding(.top, 28)
            }
            LastRunCard().padding(.top, 28)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(40)
    }

    @ViewBuilder private var notConnected: some View {
        Label(L.notConnected, systemImage: "exclamationmark.circle").font(DS.body).foregroundStyle(DS.focus)
            .fixedSize(horizontal: false, vertical: true)
        Button(L.openLightroom) { studio.backToLightroom() }.buttonStyle(QuietButton())
    }
}

/// A step of the way in: these three really are a sequence, so they are numbered.
struct StepRowText: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)").font(DS.display(24)).foregroundStyle(DS.soft).frame(width: 20, alignment: .leading)
            Text(text).font(.system(size: 17)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What is left over from last time: a run to carry on with, or one that can still be undone.
struct LastRunCard: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        if let run = studio.run, !run.undone, !run.finished || !run.done.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !run.finished {
                    Text(L.lastUnfinished(run.remaining, run.done.count)).font(DS.section).foregroundStyle(DS.ink)
                    HStack(spacing: 10) {
                        Button(L.lastContinue) { studio.work() }.buttonStyle(QuietButton())
                        Button(L.lastStop) { studio.stopRun() }.buttonStyle(QuietButton())
                    }
                } else {
                    Text(L.lastDone(run.done.count)).font(DS.section).foregroundStyle(DS.ink)
                    HStack(spacing: 10) {
                        Button(L.viewResults) { studio.startReview() }.buttonStyle(QuietButton())
                        Button(L.lastUndo) { studio.undoRun() }.buttonStyle(QuietButton())
                    }
                }
                NoticeLine()
            }
            .padding(DS.pad)
            .glass(RoundedRectangle(cornerRadius: DS.tray, style: .continuous))
            .disabled(!studio.lightroomOpen)
        } else {
            NoticeLine()
        }
    }
}

struct NoticeLine: View {
    @EnvironmentObject var studio: Studio
    var body: some View {
        if let notice = studio.notice {
            Text(notice).font(DS.label).foregroundStyle(DS.soft)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460, alignment: .leading)
        }
    }
}

struct PreparingView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 14) {
            Text(L.preparingTitle).font(DS.display(28)).foregroundStyle(DS.ink)
            Text(studio.session.map { L.preparingNote($0.name) } ?? "")
                .font(DS.body).foregroundStyle(DS.soft)
            ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 220).padding(.top, 8)
        }
    }
}

struct FailedView: View {
    @EnvironmentObject var studio: Studio
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.failedTitle).font(DS.display(28)).foregroundStyle(DS.ink)
            Text(message).font(DS.body).foregroundStyle(DS.soft)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }
            .padding(.top, 6)
        }
        .padding(30).frame(width: 520, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
    }

    @ViewBuilder private var actions: some View {
        if let run = studio.run, !run.finished {
            PrimaryButton(title: L.goOn) { studio.work() }
        }
        Button(L.backToLightroom) { studio.backToLightroom() }.buttonStyle(QuietButton())
        if !studio.looks.isEmpty {
            Button(L.back) { studio.again() }.buttonStyle(QuietButton())
        }
    }
}

// MARK: - The studio: picture, looks, retouching

struct StudioView: View {
    @EnvironmentObject var studio: Studio
    @State private var page = "look"
    @State private var barHeight: CGFloat = 210
    @State private var cardHeight: CGFloat = 170
    static let trayHeight: CGFloat = 148

    var body: some View {
        GeometryReader { box in
            let wide = box.size.width >= DS.wide
            let choosing = studio.stage == .choosing
            let ids = studio.session?.ids ?? []
            let rail = wide && ids.count > 1
            ZStack {
                if let before = studio.original, let chosen = studio.chosen, let after = studio.after {
                    Canvas(before: before.image, after: after, title: chosen.title,
                           plain: chosen.id == "none" && !studio.beautyShown,
                           retouched: studio.beautyShown, pending: !studio.pictureExact,
                           sweep: studio.stage == .working ? studio.fraction : nil,
                           clear: insets(wide: wide, rail: rail), ids: choosing ? ids : [])
                        .blur(radius: choosing && studio.loading != nil ? 14 : 0)
                        .opacity(choosing && studio.loading != nil ? 0.45 : 1)
                        .allowsHitTesting(studio.stage != .paused)
                }
                if studio.loading != nil, choosing { LoadingPhotoOverlay().transition(.scale(scale: 0.94).combined(with: .opacity)) }
                GlassEffectContainer(spacing: DS.gap) {
                    ZStack {
                        if choosing {
                            if wide { WideChrome(ids: ids, rail: rail) } else { NarrowChrome(ids: ids, page: $page, barHeight: $barHeight) }
                        } else {
                            VStack {
                                Spacer()
                                StageCard()
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                                    .padding(.bottom, DS.gap)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .animation(DS.stage, value: studio.stage)
            .animation(DS.stage, value: wide)
            .animation(DS.stage, value: page)
            .animation(.smooth(duration: 0.3), value: studio.loading)
        }
    }

    private func insets(wide: Bool, rail: Bool) -> EdgeInsets {
        if studio.stage != .choosing {
            return EdgeInsets(top: 44, leading: 40, bottom: cardHeight + DS.gap * 2 + 6, trailing: 40)
        }
        if wide {
            return EdgeInsets(top: 62, leading: rail ? PhotoRail.width + DS.gap * 2 : 24,
                              bottom: Self.trayHeight + DS.gap * 2 + 4, trailing: DS.side + DS.gap * 2 + 10)
        }
        return EdgeInsets(top: 64, leading: 16, bottom: barHeight + DS.gap + 10, trailing: 16)
    }
}

/// From 1000 pt of width: everything on one screen. Photos down the left, looks along the bottom, the rest in the
/// inspector on the right.
struct WideChrome: View {
    @EnvironmentObject var studio: Studio
    let ids: [Int]
    let rail: Bool

    var body: some View {
        ZStack {
            VStack {
                HStack(spacing: 10) {
                    PhotoStepper(ids: ids, name: ids.count > 1 ? L.appliesToAll(ids.count) : studio.session?.name)
                    Spacer(minLength: 0)
                    ZoomCluster()
                    Spacer(minLength: 0)
                }
                .padding(.leading, 84).padding(.top, 8)
                Spacer()
            }
            .padding(.trailing, DS.side + DS.gap * 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            if rail {
                HStack { PhotoRail(ids: ids, hint: L.railHint); Spacer() }
                    .padding(.leading, DS.gap).padding(.top, 62).padding(.bottom, StudioView.trayHeight + DS.gap * 2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack { Spacer(); LookTray() }
                .padding(.leading, DS.gap).padding(.trailing, DS.side + DS.gap * 2).padding(.bottom, DS.gap)
                .disabled(studio.loading != nil)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            HStack { Spacer(); Inspector() }
                .padding(.trailing, DS.gap).padding(.top, 44).padding(.bottom, DS.gap)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

/// Below 1000 pt (a narrow window, an iPad held upright): the photo takes the window and one bar of glass holds
/// the same controls, a page at a time.
struct NarrowChrome: View {
    @EnvironmentObject var studio: Studio
    let ids: [Int]
    @Binding var page: String
    @Binding var barHeight: CGFloat
    @Namespace private var space
    @Namespace private var glassSpace
    private static let pages = [("look", L.pageLook), ("beauty", L.beauty), ("more", L.pageMore)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if ids.count > 1 { PhotoStepper(ids: ids, name: nil) }
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { ZoomCluster(); RetouchButton().fixedSize() }
                    HStack(spacing: 10) { ZoomCluster(compact: true); RetouchButton().fixedSize() }
                    HStack(spacing: 10) { ZoomCluster(compact: true); RetouchButton() }
                }
            }
            .padding(.leading, 84).padding(.trailing, DS.gap).padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            Spacer()
            VStack(spacing: 10) {
                Group {
                    switch page {
                    case "look": LookPage()
                    case "beauty": BeautyPage()
                    default: MorePage()
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .glassEffectID("panel", in: glassSpace)
                .padding(.horizontal, DS.gap)
                HStack(spacing: 0) {
                    ForEach(Self.pages, id: \.0) { key, title in
                        let on = page == key
                        Button { page = key } label: {
                            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.black : DS.ink)
                                .lineLimit(1).fixedSize().padding(.horizontal, 16)
                                .frame(minWidth: 84).frame(height: DS.touch - 8)
                                .background { if on { Capsule().fill(.white).matchedGeometryEffect(id: "page", in: space) } }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .glass(Capsule(), interactive: true)
                .glassEffectID("pages", in: glassSpace)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            .padding(.bottom, DS.gap)
            .disabled(studio.loading != nil)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct RetouchButton: View {
    @EnvironmentObject var studio: Studio
    var wide = false
    var body: some View {
        PrimaryButton(title: studio.targets.count > 1 ? L.retouchMany(studio.targets.count) : L.retouchOne, wide: wide, action: studio.retouch)
            .disabled(studio.nothingToDo)
    }
}

// MARK: Photos

/// The photos handed over, down the left side, each with what the selection help found wrong with it.
struct PhotoRail: View {
    @EnvironmentObject var studio: Studio
    let ids: [Int]
    let hint: String
    static let width: CGFloat = 88
    @Namespace private var space

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(ids, id: \.self) { id in
                            Button { studio.show(id) } label: {
                                PhotoThumb(image: studio.thumbs[id], selected: studio.photo == id, loading: studio.loading == id,
                                           flags: studio.flags[id] ?? [], space: space)
                            }
                            .buttonStyle(.plain).id(id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: studio.photo) { _, now in withAnimation(DS.pick) { scroll.scrollTo(now, anchor: .center) } }
            }
            Text(hint).font(.system(size: 10)).foregroundStyle(DS.soft).multilineTextAlignment(.center)
                .lineLimit(5).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.bottom, 10).padding(.top, 4)
        }
        .frame(width: Self.width)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PhotoThumb: View {
    let image: NSImage?
    let selected: Bool
    let loading: Bool
    let flags: [String]
    let space: Namespace.ID
    static let names = ["eyes": L.flagEyes, "blur": L.flagBlur, "over": L.flagOver, "dup": L.flagDup]

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFill() } else { Rectangle().fill(DS.faint) }
                if loading { ProgressView().controlSize(.small) }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: DS.thumb, style: .continuous))
            if !flags.isEmpty {
                Text(flags.map { Self.names[$0] ?? $0 }.joined(separator: " "))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.onFocus).lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(DS.focus, in: Capsule())
                    .padding(.bottom, 3)
            }
        }
        .frame(width: 60, height: 60)
        .padding(5)
        .overlay { if selected { FocusMark().matchedGeometryEffect(id: "photo", in: space) } }
        .opacity(selected || loading ? 1 : 0.66)
        .contentShape(Rectangle())
    }
}

struct LoadingPhotoOverlay: View {
    var body: some View {
        VStack(spacing: 10) {
            Text(L.loadingTitle).font(DS.display(22)).foregroundStyle(DS.ink)
            Text(L.loadingNote).font(DS.body).foregroundStyle(DS.soft)
            ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 200).padding(.top, 6)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
    }
}

// MARK: Looks

/// One look: the photo in it, its name, a line about it. The chosen one sits in focus brackets, which slide from
/// card to card.
struct LookCard: View {
    @EnvironmentObject var studio: Studio
    let look: Look
    let width: CGFloat
    var height: CGFloat = 72
    var centred = false
    let space: Namespace.ID

    var body: some View {
        let on = studio.look == look.id
        Button { withAnimation(DS.pick) { studio.look = look.id } } label: {
            VStack(alignment: centred ? .center : .leading, spacing: 5) {
                Image(nsImage: look.image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(5)
                    .overlay { if on { FocusMark().matchedGeometryEffect(id: "look", in: space) } }
                    .padding(-5)
                Text(look.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? DS.focus : DS.ink).lineLimit(1).padding(.top, 4)
                Text(look.note).font(DS.note).foregroundStyle(DS.soft).lineLimit(1)
            }
            .frame(width: width, alignment: centred ? .center : .leading)
            .opacity(on ? 1 : 0.78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.title).accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu { if look.mine { Button(L.deleteStyle, role: .destructive) { studio.deleteStyle(look.id) } } }
    }
}

struct AddLookCard: View {
    @EnvironmentObject var studio: Studio
    let width: CGFloat
    var height: CGFloat = 72
    var centred = false
    @State private var saving = false

    var body: some View {
        Button { studio.styleError = nil; saving = true } label: {
            VStack(alignment: centred ? .center : .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.faint)
                    .frame(width: width, height: height)
                    .overlay(Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(DS.soft))
                Text(L.saveStyle).font(.system(size: 12)).foregroundStyle(DS.ink).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
                Text(L.saveStyleNote).font(DS.note).foregroundStyle(DS.soft).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: width, alignment: centred ? .center : .leading)
            .opacity(0.78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $saving) { SaveStyleSheet(showing: $saving).environmentObject(studio) }
    }
}

/// Every look at once along the bottom: the cards share the width, nothing hides behind a scroll.
struct LookTray: View {
    @EnvironmentObject var studio: Studio
    @Namespace private var space

    var body: some View {
        GeometryReader { box in
            let n = CGFloat(studio.looks.count + 1)
            let width = min(150, max(60, (box.size.width - 36 - 14 * (n - 1)) / n))
            HStack(alignment: .top, spacing: 14) {
                ForEach(studio.looks) { look in
                    LookCard(look: look, width: width, space: space).id("\(studio.photo)-\(look.id)")
                }
                AddLookCard(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: StudioView.trayHeight)
        .glass(RoundedRectangle(cornerRadius: DS.tray, style: .continuous))
    }
}

struct SaveStyleSheet: View {
    @EnvironmentObject var studio: Studio
    @Binding var showing: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.saveStyle).font(DS.display(24))
            Text(L.saveStyleText)
                .font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L.saveStyleField, text: $name)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 14).frame(height: DS.touch)
                .background(DS.faint, in: RoundedRectangle(cornerRadius: DS.chip, style: .continuous))
            if let error = studio.styleError {
                Text(error).font(DS.label).foregroundStyle(DS.focus).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if studio.savingStyle {
                    ProgressView().controlSize(.small)
                    Text(L.saveStyleBusy).font(DS.label).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.cancel) { showing = false }.buttonStyle(QuietButton()).disabled(studio.savingStyle)
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: L.save) { studio.saveStyle(named: name) { ok in if ok { showing = false } } }
                    .disabled(studio.savingStyle).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(26).frame(width: 460)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

// MARK: The controls, as the inspector lays them out and as the pages do

/// The look's name is the one headline of the screen; it rolls over when the look changes.
struct LookHeadline: View {
    @EnvironmentObject var studio: Studio
    var size: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(studio.chosen?.title ?? "").font(DS.display(size)).foregroundStyle(DS.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(studio.chosen.map { $0.id == "none" ? L.keepOriginal : $0.note } ?? "").font(DS.body).foregroundStyle(DS.soft).lineLimit(1)
        }
        .id(studio.look)
        .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .bottom)).combined(with: .opacity))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct Tweaks: View {
    @EnvironmentObject var studio: Studio
    var spacing: CGFloat = 0
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: spacing) {
            StepRow(low: L.darker, high: L.brighter, value: $studio.tweak.bright)
            StepRow(low: L.cooler, high: L.warmer, value: $studio.tweak.warm)
            StepRow(low: L.paler, high: L.richer, value: $studio.tweak.rich)
        }
        .disabled(studio.look == "none").opacity(studio.look == "none" ? 0.3 : 1)
    }
}

struct People: View {
    @EnvironmentObject var studio: Studio
    static let help = L.peopleHelp
    var body: some View {
        if studio.people.count > 1 && studio.level != .off {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48, maximum: 52), spacing: 4)], alignment: .leading, spacing: 6) {
                ForEach(studio.people) { PersonChip(person: $0) }
            }
            .help(Self.help)
        }
    }
}

enum Explain {
    static let shaping = L.shapingHelp
    static let best = L.bestHelp
    static func beauty(people: Bool) -> String { (people ? People.help + "\n\n" : "") + shaping + "\n\n" + best }
}

struct DenoiseNote: View {
    @EnvironmentObject var studio: Studio
    var body: some View {
        Text(studio.noisy
             ? L.noisyNote(studio.session?.iso ?? 0)
             : L.denoiseNote)
            .font(DS.note).foregroundStyle(studio.noisy && !studio.denoise ? DS.focus : DS.soft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SkipFlagged: View {
    @EnvironmentObject var studio: Studio
    var body: some View {
        if !studio.flagged.isEmpty {
            SwitchRow(title: L.skipFlagged(studio.flagged.count), on: $studio.skipFlagged)
        }
    }
}

struct Inspector: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    LookHeadline()
                    if studio.chosen?.mine == true {
                        Button(L.deleteStyle) { studio.deleteStyle(studio.look) }
                            .buttonStyle(.plain).font(DS.label).foregroundStyle(DS.soft)
                            .frame(height: DS.touch).contentShape(Rectangle())
                    }
                    Tweaks().padding(.horizontal, -12).padding(.top, 6)
                    Rectangle().fill(DS.line).frame(height: 1).padding(.vertical, 12)
                    HStack(spacing: 0) {
                        Text(L.beauty).font(DS.section).foregroundStyle(DS.ink)
                        Spacer()
                        InfoButton(text: Explain.beauty(people: studio.people.count > 1)).padding(.trailing, -12)
                    }
                    .frame(height: 30)
                    LevelBar().padding(.top, 6)
                    Text(studio.level.note).font(DS.note).foregroundStyle(DS.soft)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                    Group {
                        People().padding(.top, 12)
                        ShapeChips().padding(.top, 12).help(Explain.shaping)
                        SwitchRow(title: L.best, on: $studio.best).padding(.top, 6).help(Explain.best)
                    }
                    .disabled(studio.level == .off).opacity(studio.level == .off ? 0.3 : 1)
                    Rectangle().fill(DS.line).frame(height: 1).padding(.vertical, 8)
                    SwitchRow(title: L.denoise, on: $studio.denoise)
                    DenoiseNote()
                }
                .padding(.horizontal, DS.pad).padding(.top, 22).padding(.bottom, 10)
            }
            VStack(spacing: 8) {
                SkipFlagged()
                RetouchButton(wide: true)
                Text(L.safeNote).font(DS.note).foregroundStyle(DS.soft)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.pad).padding(.bottom, 16).padding(.top, 6)
        }
        .frame(width: DS.side)
        .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
    }
}

struct LookPage: View {
    @EnvironmentObject var studio: Studio
    @Namespace private var space

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(studio.looks) { look in
                            LookCard(look: look, width: 104, height: 70, centred: true, space: space).id(look.id)
                        }
                        AddLookCard(width: 104, height: 70, centred: true)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 6)
                }
                .onChange(of: studio.look) { _, now in withAnimation(DS.pick) { scroll.scrollTo(now, anchor: .center) } }
            }
            Rectangle().fill(DS.line).frame(width: 1, height: 96)
            Tweaks(spacing: -6).frame(width: 240)
        }
        .frame(height: 132)
    }
}

struct BeautyPage: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                level.frame(width: 330)
                Rectangle().fill(DS.line).frame(width: 1, height: 96)
                rest(columns: 3).frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 10) {
                level
                rest(columns: 6)
            }
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelBar()
            HStack(alignment: .top, spacing: 0) {
                Text(studio.level.note).font(DS.note).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func rest(columns: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if studio.people.count > 1 && studio.level != .off { People().frame(width: 156) }
            ShapeChips(columns: columns)
            InfoButton(text: Explain.beauty(people: studio.people.count > 1)).padding(.horizontal, -10)
        }
        .disabled(studio.level == .off).opacity(studio.level == .off ? 0.3 : 1)
    }
}

struct MorePage: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { switches; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 0) { switches }
            }
            DenoiseNote()
            SkipFlagged()
            Text(L.safeNote).font(DS.note).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var switches: some View {
        SwitchRow(title: L.best, on: $studio.best).fixedSize()
            .disabled(studio.level == .off).opacity(studio.level == .off ? 0.3 : 1)
        SwitchRow(title: L.denoise, on: $studio.denoise).fixedSize()
    }
}

// MARK: - While Lightroom works, and afterwards

/// One card at the bottom for the three states after the button: working, paused, finished. The photo above it
/// stays the subject: while Lightroom works, the result spreads across it as far as the work has got.
struct StageCard: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        Group {
            switch studio.stage {
            case .working: working
            case .paused: paused
            default: finished
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: 620)
        .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
        .padding(.horizontal, DS.gap)
    }

    @ViewBuilder private var working: some View {
        if let run = studio.run {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.ids.count > 1 ? L.workingMany(run.ids.count) : L.workingOne).font(DS.display(24)).foregroundStyle(DS.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Text(studio.fraction.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.ink).contentTransition(.numericText())
                }
                GeometryReader { box in
                    Capsule().fill(DS.faint)
                    Capsule().fill(.white).frame(width: max(4, box.size.width * studio.fraction))
                }
                .frame(height: 4)
                HStack(spacing: 12) {
                    Text(run.level != "off" && run.ids.count > 1 ? L.doneOf(run.done.count, run.ids.count, studio.caption) : studio.caption)
                        .font(DS.body).foregroundStyle(DS.soft).lineLimit(2)
                    Spacer()
                    if run.ids.count > 3 {
                        Button(studio.pauseAsked ? L.pauseAsked : L.pause) { studio.pauseAsked = true }
                            .buttonStyle(QuietButton()).disabled(studio.pauseAsked)
                    }
                }
                .frame(minHeight: DS.touch)
            }
        }
    }

    @ViewBuilder private var paused: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.pausedTitle).font(DS.display(24)).foregroundStyle(DS.ink)
            if let run = studio.run {
                Text(L.pausedNote(run.done.count, run.remaining))
                    .font(DS.body).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                PrimaryButton(title: L.goOn, action: studio.work)
                Button(L.stopHere) { studio.stopRun() }.buttonStyle(QuietButton())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var finished: some View {
        if let run = studio.run {
            VStack(alignment: .leading, spacing: 10) {
                Text(run.undone ? L.undoneTitle : (run.done.count > 1 ? L.finishedMany(run.done.count) : L.finishedOne))
                    .font(DS.display(28)).foregroundStyle(DS.ink)
                if !run.undone {
                    Text(run.created.isEmpty ? L.tonedNote : L.stackedNote)
                        .font(DS.body).foregroundStyle(DS.soft)
                }
                if !run.failed.isEmpty && !run.undone {
                    HStack(spacing: 10) {
                        Text(L.failedCount(run.failed.count)).font(DS.body).foregroundStyle(DS.focus)
                        Button(L.retryCount(run.failed.count)) { studio.retryFailed() }.buttonStyle(QuietButton())
                    }
                }
                NoticeLine()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions(run) }
                    VStack(alignment: .leading, spacing: 10) { actions(run) }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func actions(_ run: Run) -> some View {
        if !run.undone { PrimaryButton(title: L.viewResults, action: studio.startReview) }
        Button(L.backToLightroom) { studio.backToLightroom() }.buttonStyle(QuietButton())
        Button(L.again) { studio.again() }.buttonStyle(QuietButton())
        if !run.undone { Button(L.undoRun) { studio.undoRun() }.buttonStyle(QuietButton()) }
    }
}

/// The finished pictures next to how the photos were, one photo at a time.
struct ReviewView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        GeometryReader { box in
            let ids = studio.run?.done ?? []
            let rail = box.size.width >= DS.wide && ids.count > 1
            ZStack {
                if let before = studio.befores[studio.photo], let after = studio.results[studio.photo] {
                    Canvas(before: before, after: after, title: L.resultLabel,
                           clear: EdgeInsets(top: 62, leading: rail ? PhotoRail.width + DS.gap * 2 : 24, bottom: DS.touch + DS.gap * 2 + 4, trailing: 24),
                           ids: ids)
                } else {
                    VStack(spacing: 12) {
                        Text(L.fetchingResult).font(DS.body).foregroundStyle(DS.soft)
                        ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 200)
                    }
                }
                GlassEffectContainer(spacing: DS.gap) {
                    ZStack {
                        VStack {
                            HStack(spacing: 10) {
                                if ids.count > 1 { PhotoStepper(ids: ids, name: nil) }
                                Spacer(minLength: 0)
                                ZoomCluster()
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 84).padding(.trailing, 84).padding(.top, 8)
                            Spacer()
                            HStack(spacing: 10) {
                                Spacer()
                                Button(L.undoRun) { studio.undoRun(); studio.leaveReview() }.buttonStyle(QuietButton())
                                PrimaryButton(title: L.reviewDone, action: studio.leaveReview)
                            }
                            .padding(.horizontal, DS.gap).padding(.bottom, DS.gap)
                        }
                        if rail {
                            HStack { PhotoRail(ids: ids, hint: L.reviewRailHint); Spacer() }
                                .padding(.leading, DS.gap).padding(.top, 62).padding(.bottom, DS.gap)
                        }
                    }
                }
            }
        }
    }
}
