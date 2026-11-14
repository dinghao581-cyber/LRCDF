import SwiftUI
import AppKit

// "Rights" screens: launch prompt, rights card, break reminder.
// Self-contained. Wiring (see legal/RIGHTS_WIRING.md): RootView shows `RightsHost`
// as an overlay / sheet, the Help menu calls `RightsCenter.shared.openCard()`.
// General information about Australian (ACT) law, not legal advice. The app does not use the
// network: links open in the user's browser only when clicked.

enum RightsText {
    static let question = "您是否正在剥削性工作中？"
    static let invite = "了解您拥有的权利。"
    static let disclaimer = "以下为一般性信息，不是法律意见，依据澳大利亚联邦法律和首都领地（堪培拉，ACT）的规定。如果你在其他地方工作，当地法律可能不同。"

    struct Point: Identifiable { let id = UUID(); let title: String; let body: String }
    struct Help: Identifiable { let id = UUID(); let name: String; let how: String; let url: String? }

    static let points: [Point] = [
        .init(title: "报酬", body: "雇员有权获得至少法定最低工资，以及按所适用的行业裁定（award）或协议应得的加班、周末和公共假日待遇。如果“无薪”做的是真正的工作，而不是很短的、合理的评估，通常是违法的。"),
        .init(title: "工时与休息", body: "全职每周标准工时是 38 小时；超出的部分必须合理，你有权拒绝不合理的加班。你也有权享有休息和假期（年假、病假等，按雇用类型而定）。"),
        .init(title: "“假承包”", body: "把雇员硬说成“自由职业者/承包人”来逃避工资和福利，可能构成假承包（sham contracting），是违法的。拿不准自己的身份，可以免费咨询公平工作监察专员。"),
        .init(title: "署名与作品", body: "作者对自己的作品享有精神权利：被署名，作品不被歪曲。雇用关系里版权通常归雇主，但精神权利仍在你手上，除非你书面同意放弃。"),
        .init(title: "安全与健康", body: "雇主有责任在合理可行的范围内提供安全、健康的工作环境，包括合理的工作量和休息。长时间连续工作造成的伤害，也是工作安全问题。"),
        .init(title: "不被报复", body: "你行使自己的工作权利（提问、投诉、请假）时，雇主不能因此解雇你、削减工时或区别对待。"),
        .init(title: "强迫劳动", body: "以债务、威胁或暴力逼人工作是刑事犯罪，与你是什么身份或签证无关；扣押护照或证件可能构成犯罪，也是强迫劳动的警示信号。遇到危险请立刻拨打 000。"),
        .init(title: "签证持有人", body: "持工作、学生或其他签证的人，同样享有基本的工作权利，向监察专员求助本身不会取消你的签证（只有内政部能取消签证），符合条件的人还有举报保护。具体情况请向官方或法律援助确认。"),
    ]

    static let help: [Help] = [
        .init(name: "公平工作监察专员（Fair Work Ombudsman）", how: "免费咨询，可使用翻译服务。电话 13 13 94", url: "https://www.fairwork.gov.au"),
        .init(name: "公平工作委员会（Fair Work Commission）", how: "不公平解雇、欺凌等申请", url: "https://www.fwc.gov.au"),
        .init(name: "WorkSafe ACT", how: "堪培拉的工作安全与健康", url: "https://www.worksafe.act.gov.au"),
        .init(name: "ACT 法律援助（Legal Aid ACT）", how: "免费或低价法律帮助。求助热线 1300 654 314", url: "https://legalaidact.org.au"),
        .init(name: "ACT 人权委员会", how: "歧视和骚扰投诉", url: "https://hrc.act.gov.au"),
        .init(name: "澳大利亚联邦警察（AFP）", how: "强迫劳动、人口贩运举报。电话 131 237；紧急情况拨 000", url: "https://www.afp.gov.au"),
        .init(name: "笔译和口译服务（TIS National）", how: "打电话时需要翻译，拨 131 450", url: "https://www.tisnational.gov.au"),
        .init(name: "Lifeline", how: "情绪支持，24 小时。电话 13 11 14", url: "https://www.lifeline.org.au"),
    ]
}

/// Remembers the "don't show again" choice and drives what is on screen.
final class RightsCenter: ObservableObject {
    static let shared = RightsCenter()
    private let hideKey = "rights.hidePrompt"
    private let breakKey = "rights.breakReminder"

    @Published var showPrompt: Bool
    @Published var showCard = false
    @Published var breakDue = false
    @Published var breakEnabled: Bool {
        didSet { UserDefaults.standard.set(breakEnabled, forKey: breakKey) }
    }

    /// Active minutes in a row; resets after ten minutes away from the app.
    private var activeSeconds = 0
    private var awaySeconds = 0
    private var timer: Timer?
    static let breakAfter = 90 * 60

    init() {
        showPrompt = !UserDefaults.standard.bool(forKey: hideKey)
        breakEnabled = UserDefaults.standard.object(forKey: breakKey) as? Bool ?? true
    }

    func dismissPrompt(dontAskAgain: Bool) {
        if dontAskAgain { UserDefaults.standard.set(true, forKey: hideKey) }
        showPrompt = false
    }
    func openCard() { showPrompt = false; showCard = true }
    /// Lets the user turn the launch prompt on again from the card.
    var promptEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: hideKey) }
        set { UserDefaults.standard.set(!newValue, forKey: hideKey); objectWillChange.send() }
    }

    func startBreakTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        if NSApp.isActive {
            awaySeconds = 0
            activeSeconds += 30
        } else {
            awaySeconds += 30
            if awaySeconds >= 600 { activeSeconds = 0 }
        }
        if breakEnabled && !breakDue && activeSeconds >= Self.breakAfter { breakDue = true }
    }
    func breakAcknowledged(rest: Bool) {
        breakDue = false
        activeSeconds = rest ? 0 : Self.breakAfter - 30 * 60   // "later": ask again in 30 minutes
    }
}

/// Put once over the main view: `RootView().overlay(RightsHost())`.
struct RightsHost: View {
    @ObservedObject private var center = RightsCenter.shared

    var body: some View {
        ZStack {
            if center.showPrompt { RightsPrompt().transition(.opacity) }
            if center.showCard { RightsCard().transition(.opacity) }
            VStack {
                Spacer()
                if center.breakDue { BreakBanner().padding(24).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.showPrompt)
        .animation(.easeOut(duration: 0.2), value: center.showCard)
        .animation(.easeOut(duration: 0.2), value: center.breakDue)
        .onAppear { center.startBreakTimer() }
    }
}

private struct Backdrop: View {
    var body: some View { Color.black.opacity(0.62).ignoresSafeArea() }
}

struct RightsPrompt: View {
    @ObservedObject private var center = RightsCenter.shared
    @State private var dontAsk = false

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 18) {
                Text(RightsText.question).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
                Text(RightsText.invite).font(.system(size: 16)).foregroundStyle(Palette.soft)
                HStack(spacing: 12) {
                    Button { center.openCard() } label: {
                        Text("了解我的权利").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Palette.glow, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                    Button { center.dismissPrompt(dontAskAgain: dontAsk) } label: {
                        Text("没有，继续").font(.system(size: 14)).padding(.horizontal, 18).padding(.vertical, 9)
                            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                .padding(.top, 4)
                Toggle("不再提示", isOn: $dontAsk).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Palette.soft)
            }
            .padding(32).frame(width: 460)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
        }
    }
}

struct RightsCard: View {
    @ObservedObject private var center = RightsCenter.shared

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("您拥有的权利").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button { center.showCard = false } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain)
                }
                .padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(RightsText.disclaimer).font(.system(size: 12)).foregroundStyle(Palette.soft)
                        ForEach(RightsText.points) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title).font(.system(size: 14, weight: .semibold))
                                Text(p.body).font(.system(size: 13)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider().overlay(Palette.line)
                        Text("在哪里求助").font(.system(size: 14, weight: .semibold))
                        ForEach(RightsText.help) { h in
                            VStack(alignment: .leading, spacing: 2) {
                                if let u = h.url, let url = URL(string: u) {
                                    Link(h.name, destination: url).font(.system(size: 13, weight: .medium))
                                } else { Text(h.name).font(.system(size: 13, weight: .medium)) }
                                Text(h.how).font(.system(size: 12)).foregroundStyle(Palette.soft)
                            }
                        }
                        Divider().overlay(Palette.line)
                        Toggle("每次打开时提醒我这些权利", isOn: Binding(get: { center.promptEnabled }, set: { center.promptEnabled = $0 }))
                            .toggleStyle(.checkbox).font(.system(size: 13))
                        Toggle("连续工作 1.5 小时后提醒休息", isOn: $center.breakEnabled)
                            .toggleStyle(.checkbox).font(.system(size: 13))
                    }
                    .padding(.trailing, 8)
                }
            }
            .padding(26).frame(width: 560, height: 600)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
        }
    }
}

struct BreakBanner: View {
    @ObservedObject private var center = RightsCenter.shared
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cup.and.saucer")
            Text("已经连续工作约 1.5 小时了，起来活动一下、喝口水吧。").font(.system(size: 14))
            Spacer(minLength: 12)
            Button("去休息") { center.breakAcknowledged(rest: true) }.buttonStyle(.plain).foregroundStyle(Palette.glowB)
            Button("30 分钟后再说") { center.breakAcknowledged(rest: false) }.buttonStyle(.plain).foregroundStyle(Palette.soft)
        }
        .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: 680)
        .background(Palette.panel, in: Capsule()).overlay(Capsule().stroke(Palette.line, lineWidth: 1))
    }
}
