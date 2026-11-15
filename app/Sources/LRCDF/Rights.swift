import SwiftUI
import AppKit

// "Rights" screens: launch prompt, rights card, break reminder.
// Self-contained. Wiring (see legal/RIGHTS_WIRING.md): RootView shows `RightsHost`
// as an overlay / sheet, the Help menu calls `RightsCenter.shared.openCard()`.
// General information about Australian (ACT) law, not legal advice. The app does not use the
// network: links open in the user's browser only when clicked.

enum RightsText {
    static let question = L.rightsQuestion
    static let invite = L.rightsInvite
    static let disclaimer = L.rightsDisclaimer

    struct Point: Identifiable { let id = UUID(); let title: String; let body: String }
    struct Help: Identifiable { let id = UUID(); let name: String; let how: String; let url: String? }

    static let points: [Point] = [
        .init(title: L.rightsPayTitle, body: L.rightsPayBody),
        .init(title: L.rightsHoursTitle, body: L.rightsHoursBody),
        .init(title: L.rightsShamTitle, body: L.rightsShamBody),
        .init(title: L.rightsCreditTitle, body: L.rightsCreditBody),
        .init(title: L.rightsSafetyTitle, body: L.rightsSafetyBody),
        .init(title: L.rightsReprisalTitle, body: L.rightsReprisalBody),
        .init(title: L.rightsForcedTitle, body: L.rightsForcedBody),
        .init(title: L.rightsVisaTitle, body: L.rightsVisaBody),
    ]

    static let help: [Help] = [
        .init(name: L.helpFWO, how: L.helpFWOHow, url: "https://www.fairwork.gov.au"),
        .init(name: L.helpFWC, how: L.helpFWCHow, url: "https://www.fwc.gov.au"),
        .init(name: "WorkSafe ACT", how: L.helpWorkSafeHow, url: "https://www.worksafe.act.gov.au"),
        .init(name: L.helpLegalAid, how: L.helpLegalAidHow, url: "https://legalaidact.org.au"),
        .init(name: L.helpHRC, how: L.helpHRCHow, url: "https://hrc.act.gov.au"),
        .init(name: L.helpAFP, how: L.helpAFPHow, url: "https://www.afp.gov.au"),
        .init(name: L.helpTIS, how: L.helpTISHow, url: "https://www.tisnational.gov.au"),
        .init(name: "Lifeline", how: L.helpLifelineHow, url: "https://www.lifeline.org.au"),
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
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.showPrompt)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.showCard)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.breakDue)
        .onAppear { center.startBreakTimer() }
    }
}

struct RightsPrompt: View {
    @ObservedObject private var center = RightsCenter.shared
    @State private var dontAsk = false

    var body: some View {
        DialogPanel(width: 460, spacing: 18) {
            Text(RightsText.question).font(DS.display(26)).foregroundStyle(DS.ink).multilineTextAlignment(.center)
            Text(RightsText.invite).font(.system(size: 16)).foregroundStyle(DS.soft)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { choices }
                VStack(spacing: 10) { choices }
            }
            .padding(.top, 4)
            Toggle(L.rightsDontAsk, isOn: $dontAsk).toggleStyle(.checkbox).font(DS.label).foregroundStyle(DS.soft)
                .frame(minHeight: DS.touch)
        }
    }

    @ViewBuilder private var choices: some View {
        PrimaryButton(title: L.rightsOpen) { center.openCard() }
        Button(L.rightsDismiss) { center.dismissPrompt(dontAskAgain: dontAsk) }.buttonStyle(QuietButton())
    }
}

struct RightsCard: View {
    @ObservedObject private var center = RightsCenter.shared

    var body: some View {
        DialogPanel(width: 560, spacing: 0, alignment: .leading) {
            HStack {
                Text(L.rightsTitle).font(DS.display(24)).foregroundStyle(DS.ink)
                Spacer()
                IconButton(symbol: "xmark", label: L.close) { center.showCard = false }.foregroundStyle(DS.ink)
            }
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(RightsText.disclaimer).font(DS.label).foregroundStyle(DS.soft)
                    ForEach(RightsText.points) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.ink)
                            Text(p.body).font(DS.body).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Rectangle().fill(DS.line).frame(height: 1)
                    Text(L.rightsWhere).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.ink)
                    ForEach(RightsText.help) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            if let u = h.url, let url = URL(string: u) {
                                Link(h.name, destination: url).font(.system(size: 13, weight: .medium)).tint(DS.ink).underline()
                            } else { Text(h.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.ink) }
                            Text(h.how).font(DS.label).foregroundStyle(DS.soft)
                        }
                    }
                    Rectangle().fill(DS.line).frame(height: 1)
                    Toggle(L.rightsRemind, isOn: Binding(get: { center.promptEnabled }, set: { center.promptEnabled = $0 }))
                        .toggleStyle(.checkbox).font(DS.body).foregroundStyle(DS.ink)
                    Toggle(L.breakRemind, isOn: $center.breakEnabled)
                        .toggleStyle(.checkbox).font(DS.body).foregroundStyle(DS.ink)
                }
                .padding(.trailing, 8)
            }
            .frame(height: 500)
        }
    }
}

struct BreakBanner: View {
    @ObservedObject private var center = RightsCenter.shared
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cup.and.saucer").foregroundStyle(DS.ink)
            Text(L.breakText).font(.system(size: 14)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(L.breakRest) { center.breakAcknowledged(rest: true) }.buttonStyle(.plain).foregroundStyle(DS.focus)
                .frame(height: DS.touch).contentShape(Rectangle())
            Button(L.breakLater) { center.breakAcknowledged(rest: false) }.buttonStyle(.plain).foregroundStyle(DS.soft)
                .frame(height: DS.touch).contentShape(Rectangle())
        }
        .padding(.horizontal, 22).padding(.vertical, 6).frame(maxWidth: 760)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
