import ImageIO
import SwiftUI

// The rights screens of the Mac and Windows apps (user's decision 2026-11-14, legal/RIGHTS_WIRING.md), for the iPad:
// a prompt at every start with 不再提示, the rights card (Australia / Canberra ACT only) and a break reminder after
// 90 minutes of use. The texts are the Mac app's, word for word (app/Sources/LRCDF/Strings.swift rights.* keys, copied
// by script; do not reword them here). No network: a link opens in the browser only when it is tapped.

enum RL {
    static let rightsMenu = "了解您拥有的权利…"      // rights.menu
    static let rightsQuestion = "您是否正在剥削性工作中？"      // rights.question
    static let rightsInvite = "了解您拥有的权利。"      // rights.invite
    static let rightsOpen = "了解我的权利"      // rights.open
    static let rightsDismiss = "没有，继续"      // rights.dismiss
    static let rightsDontAsk = "不再提示"      // rights.dontAsk
    static let rightsTitle = "您拥有的权利"      // rights.title
    static let rightsDisclaimer = "以下为一般性信息，不是法律意见，依据澳大利亚联邦法律和首都领地（堪培拉，ACT）的规定。如果你在其他地方工作，当地法律可能不同。"      // rights.disclaimer
    static let rightsPayTitle = "报酬"      // rights.pay.title
    static let rightsPayBody = "雇员有权获得至少法定最低工资，以及按所适用的行业裁定（award）或协议应得的加班、周末和公共假日待遇。如果“无薪”做的是真正的工作，而不是很短的、合理的评估，通常是违法的。"      // rights.pay.body
    static let rightsHoursTitle = "工时与休息"      // rights.hours.title
    static let rightsHoursBody = "全职每周标准工时是 38 小时；超出的部分必须合理，你有权拒绝不合理的加班。你也有权享有休息和假期（年假、病假等，按雇用类型而定）。"      // rights.hours.body
    static let rightsShamTitle = "“假承包”"      // rights.sham.title
    static let rightsShamBody = "把雇员硬说成“自由职业者/承包人”来逃避工资和福利，可能构成假承包（sham contracting），是违法的。拿不准自己的身份，可以免费咨询公平工作监察专员。"      // rights.sham.body
    static let rightsCreditTitle = "署名与作品"      // rights.credit.title
    static let rightsCreditBody = "作者对自己的作品享有精神权利：被署名，作品不被歪曲。雇用关系里版权通常归雇主，但精神权利仍在你手上，除非你书面同意放弃。"      // rights.credit.body
    static let rightsSafetyTitle = "安全与健康"      // rights.safety.title
    static let rightsSafetyBody = "雇主有责任在合理可行的范围内提供安全、健康的工作环境，包括合理的工作量和休息。长时间连续工作造成的伤害，也是工作安全问题。"      // rights.safety.body
    static let rightsReprisalTitle = "不被报复"      // rights.reprisal.title
    static let rightsReprisalBody = "你行使自己的工作权利（提问、投诉、请假）时，雇主不能因此解雇你、削减工时或区别对待。"      // rights.reprisal.body
    static let rightsForcedTitle = "强迫劳动"      // rights.forced.title
    static let rightsForcedBody = "以债务、威胁或暴力逼人工作是刑事犯罪，与你是什么身份或签证无关；扣押护照或证件可能构成犯罪，也是强迫劳动的警示信号。遇到危险请立刻拨打 000。"      // rights.forced.body
    static let rightsVisaTitle = "签证持有人"      // rights.visa.title
    static let rightsVisaBody = "持工作、学生或其他签证的人，同样享有基本的工作权利，向监察专员求助本身不会取消你的签证（只有内政部能取消签证），符合条件的人还有举报保护。具体情况请向官方或法律援助确认。"      // rights.visa.body
    static let rightsWhere = "在哪里求助"      // rights.help.title
    static let helpFWO = "公平工作监察专员（Fair Work Ombudsman）"      // rights.help.fwo
    static let helpFWOHow = "免费咨询，可使用翻译服务。电话 13 13 94"      // rights.help.fwo.how
    static let helpFWC = "公平工作委员会（Fair Work Commission）"      // rights.help.fwc
    static let helpFWCHow = "不公平解雇、欺凌等申请"      // rights.help.fwc.how
    static let helpWorkSafeHow = "堪培拉的工作安全与健康"      // rights.help.worksafe.how
    static let helpLegalAid = "ACT 法律援助（Legal Aid ACT）"      // rights.help.legalaid
    static let helpLegalAidHow = "免费或低价法律帮助。求助热线 1300 654 314"      // rights.help.legalaid.how
    static let helpHRC = "ACT 人权委员会"      // rights.help.hrc
    static let helpHRCHow = "歧视和骚扰投诉"      // rights.help.hrc.how
    static let helpAFP = "澳大利亚联邦警察（AFP）"      // rights.help.afp
    static let helpAFPHow = "强迫劳动、人口贩运举报。电话 131 237；紧急情况拨 000"      // rights.help.afp.how
    static let helpTIS = "笔译和口译服务（TIS National）"      // rights.help.tis
    static let helpTISHow = "打电话时需要翻译，拨 131 450"      // rights.help.tis.how
    static let helpLifelineHow = "情绪支持，24 小时。电话 13 11 14"      // rights.help.lifeline.how
    static let rightsRemind = "每次打开时提醒我这些权利"      // rights.remindAtLaunch
    static let breakRemind = "连续工作 1.5 小时后提醒休息"      // rights.breakReminder
    static let breakText = "已经连续工作约 1.5 小时了，起来活动一下、喝口水吧。"      // break.text
    static let breakRest = "去休息"      // break.rest
    static let breakLater = "30 分钟后再说"      // break.later
}

enum RightsText {
    struct Point: Identifiable { let id = UUID(); let title: String; let body: String }
    struct Help: Identifiable { let id = UUID(); let name: String; let how: String; let url: String? }
    static let points: [Point] = [
        .init(title: RL.rightsPayTitle, body: RL.rightsPayBody),
        .init(title: RL.rightsHoursTitle, body: RL.rightsHoursBody),
        .init(title: RL.rightsShamTitle, body: RL.rightsShamBody),
        .init(title: RL.rightsCreditTitle, body: RL.rightsCreditBody),
        .init(title: RL.rightsSafetyTitle, body: RL.rightsSafetyBody),
        .init(title: RL.rightsReprisalTitle, body: RL.rightsReprisalBody),
        .init(title: RL.rightsForcedTitle, body: RL.rightsForcedBody),
        .init(title: RL.rightsVisaTitle, body: RL.rightsVisaBody),
    ]
    static let help: [Help] = [
        .init(name: RL.helpFWO, how: RL.helpFWOHow, url: "https://www.fairwork.gov.au"),
        .init(name: RL.helpFWC, how: RL.helpFWCHow, url: "https://www.fwc.gov.au"),
        .init(name: "WorkSafe ACT", how: RL.helpWorkSafeHow, url: "https://www.worksafe.act.gov.au"),
        .init(name: RL.helpLegalAid, how: RL.helpLegalAidHow, url: "https://legalaidact.org.au"),
        .init(name: RL.helpHRC, how: RL.helpHRCHow, url: "https://hrc.act.gov.au"),
        .init(name: RL.helpAFP, how: RL.helpAFPHow, url: "https://www.afp.gov.au"),
        .init(name: RL.helpTIS, how: RL.helpTISHow, url: "https://www.tisnational.gov.au"),
        .init(name: "Lifeline", how: RL.helpLifelineHow, url: "https://www.lifeline.org.au"),
    ]
}

/// The two local switches (same keys as the Mac app) and what is on screen.
@MainActor
final class RightsCenter: ObservableObject {
    static let shared = RightsCenter()
    private let hideKey = "rights.hidePrompt"
    private let breakKey = "rights.breakReminder"

    @Published var showPrompt: Bool
    @Published var showCard = false
    @Published var breakDue = false
    @Published var breakEnabled: Bool { didSet { UserDefaults.standard.set(breakEnabled, forKey: breakKey) } }

    /// Seconds of use in a row; ten minutes away from the app start the count again.
    private var activeSeconds = 0, awaySeconds = 0
    private var timer: Timer?
    var active = true
    static let breakAfter = 90 * 60

    init() {
        showPrompt = !UserDefaults.standard.bool(forKey: "rights.hidePrompt")
        breakEnabled = UserDefaults.standard.object(forKey: "rights.breakReminder") as? Bool ?? true
    }

    func dismissPrompt(dontAskAgain: Bool) {
        if dontAskAgain { UserDefaults.standard.set(true, forKey: hideKey) }
        showPrompt = false
    }
    func openCard() { showPrompt = false; showCard = true }
    var promptEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: hideKey) }
        set { UserDefaults.standard.set(!newValue, forKey: hideKey); objectWillChange.send() }
    }

    func startBreakTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in RightsCenter.shared.tick() } }
    }
    private func tick() {
        if active { awaySeconds = 0; activeSeconds += 30 } else { awaySeconds += 30; if awaySeconds >= 600 { activeSeconds = 0 } }
        if breakEnabled && !breakDue && activeSeconds >= Self.breakAfter { breakDue = true }
    }
    func breakAcknowledged(rest: Bool) {
        breakDue = false
        activeSeconds = rest ? 0 : Self.breakAfter - 30 * 60       // "later": ask again in 30 minutes
    }
}

/// Over the whole app (RootView). `quiet`: work is going on or the tutorial is up - the prompt waits.
struct RightsHost: View {
    @ObservedObject private var center = RightsCenter.shared
    var quiet: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if center.showPrompt && !quiet { RightsPrompt().transition(.opacity) }
            if center.showCard { RightsCard().transition(.opacity) }
            VStack {
                Spacer()
                if center.breakDue && !quiet { BreakBanner().padding(24).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.showPrompt && !quiet)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.showCard)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.breakDue)
        .onAppear { center.startBreakTimer() }
        .onChange(of: phase) { _, p in center.active = p == .active }
    }
}

/// A floating glass panel over a veil (the Mac app's DialogPanel).
struct DialogPanel<Content: View>: View {
    var width: CGFloat = 480
    var spacing: CGFloat = 16
    var alignment: HorizontalAlignment = .center
    @ViewBuilder var content: () -> Content
    @State private var arrived = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: alignment, spacing: spacing) { content() }
                .padding(30).frame(maxWidth: width)
                .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
                .padding(24)
                .scaleEffect(arrived ? 1 : 0.94)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(.spring(duration: 0.45, bounce: 0.2)) { arrived = true } }
    }
}

/// A tick box (iPadOS has no checkbox toggle): the whole line is the target.
struct TickBox: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 18))
                    .foregroundStyle(on ? DS.focus : DS.soft)
                Text(title).font(DS.body).foregroundStyle(DS.ink).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: DS.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The prompt at start: a quiet page over the darkroom, the question large between focus brackets, the two
/// choices under it (user's choice of three designs, 2026-11-15: docs/ipad/权利提示_三个方案.jpg, no. 3).
struct RightsPrompt: View {
    @ObservedObject private var center = RightsCenter.shared
    @State private var dontAsk = false
    @State private var arrived = false

    var body: some View {
        ZStack {
            poster
            VStack(spacing: 30) {
                VStack(spacing: 12) {
                    Text(RL.rightsQuestion).font(DS.display(40)).foregroundStyle(DS.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(RL.rightsInvite).font(.system(size: 19)).foregroundStyle(DS.soft)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44).padding(.vertical, 34)
                .overlay { FocusMark(arm: 22).scaleEffect(arrived ? 1 : 1.12).opacity(arrived ? 1 : 0) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { choices }
                    VStack(spacing: 10) { choices }
                }
                TickBox(title: RL.rightsDontAsk, on: $dontAsk).fixedSize()
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.2).delay(0.1)) { arrived = true } }     // the brackets settle, as a focus lock
    }

    /// A realistic poster photo behind the question (made with gpt-image-2 by ipad/scripts/gen_rights_bg.py, no text, logos
    /// or emblems; the user chose five of six, 2026-11-15), a different one at each start; darkened behind the words.
    static let posters = ["r1_studio_break", "r3_walk_home", "r4_hands", "r5_rest", "r6_talk"]
    @State private var posterName = RightsPrompt.posters.randomElement()!
    @ViewBuilder private var poster: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                if let url = Bundle.main.url(forResource: posterName, withExtension: "jpg"),
                   let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    Image(decorative: cg, scale: 1).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                }
                Color.black.opacity(0.18)
                EllipticalGradient(colors: [.black.opacity(0.62), .black.opacity(0.35), .black.opacity(0.0)],
                                   center: UnitPoint(x: 0.5, y: 0.47), startRadiusFraction: 0, endRadiusFraction: 0.62)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var choices: some View {
        Button(RL.rightsDismiss) { center.dismissPrompt(dontAskAgain: dontAsk) }.buttonStyle(QuietButton())
        PrimaryButton(title: RL.rightsOpen) { center.openCard() }
    }
}

struct RightsCard: View {
    @ObservedObject private var center = RightsCenter.shared
    var body: some View {
        DialogPanel(width: 600, spacing: 0, alignment: .leading) {
            HStack {
                Text(RL.rightsTitle).font(DS.display(24)).foregroundStyle(DS.ink)
                Spacer()
                Button { center.showCard = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: DS.touch, height: DS.touch).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(DS.ink).accessibilityLabel("关闭")
            }
            .padding(.bottom, 8)
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    Text(RL.rightsDisclaimer).font(DS.label).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                    ForEach(RightsText.points) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                            Text(p.body).font(.system(size: 14)).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Rectangle().fill(DS.line).frame(height: 1)
                    Text(RL.rightsWhere).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink)
                    ForEach(RightsText.help) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            if let u = h.url, let url = URL(string: u) {
                                Link(h.name, destination: url).font(.system(size: 14, weight: .medium)).tint(DS.ink).underline()
                            } else { Text(h.name).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.ink) }
                            Text(h.how).font(.system(size: 13)).foregroundStyle(DS.soft)
                        }
                    }
                    Rectangle().fill(DS.line).frame(height: 1)
                    TickBox(title: RL.rightsRemind, on: Binding(get: { center.promptEnabled }, set: { center.promptEnabled = $0 }))
                    TickBox(title: RL.breakRemind, on: $center.breakEnabled)
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 560)
        }
    }
}

struct BreakBanner: View {
    @ObservedObject private var center = RightsCenter.shared
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cup.and.saucer").foregroundStyle(DS.ink)
            Text(RL.breakText).font(.system(size: 14)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(RL.breakRest) { center.breakAcknowledged(rest: true) }.buttonStyle(.plain).foregroundStyle(DS.focus)
                .frame(height: DS.touch).contentShape(Rectangle())
            Button(RL.breakLater) { center.breakAcknowledged(rest: false) }.buttonStyle(.plain).foregroundStyle(DS.soft)
                .frame(height: DS.touch).contentShape(Rectangle())
        }
        .padding(.horizontal, 22).padding(.vertical, 6).frame(maxWidth: 760)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
