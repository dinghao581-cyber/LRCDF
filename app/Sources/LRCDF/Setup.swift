import SwiftUI

/// The all-in-one app carries everything it needs in Contents/Resources/LRCDF (packaging/make_bundle.sh): Python with
/// its packages, the models, the scripts and the Lightroom plug-in. The first time it is opened, and again after an
/// update, it puts them in place by running first_run.sh from its own bundle. Nothing is downloaded.
/// The small developer build has no such folder and does nothing here.
final class Setup: ObservableObject {
    static let shared = Setup()
    enum State: Equatable { case idle, working(String), done, failed(String) }
    @Published var state: State = .idle

    private var payload: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("LRCDF"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("VERSION").path) else { return nil }
        return url
    }

    func runIfNeeded() {
        guard state == .idle, let payload, let script = Bundle.main.url(forResource: "first_run", withExtension: "sh") else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let have = try? String(contentsOf: home.appendingPathComponent("LRCDF/.installed_version"), encoding: .utf8)
        let want = try? String(contentsOf: payload.appendingPathComponent("VERSION"), encoding: .utf8)
        guard have == nil || have != want else { return }
        state = .working(L.setupPreparing)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, payload.path, Bundle.main.bundlePath]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        var log = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            log += text
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("step ") }) {
                DispatchQueue.main.async { if case .working = self.state { self.state = .working(String(line.dropFirst(5))) } }
            }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                switch p.terminationStatus {
                case 0: self.state = .done
                case 3: self.state = .idle          // a developer's checkout: left alone
                default: self.state = .failed(String(log.suffix(400)))
                }
            }
        }
        do { try process.run() } catch { state = .failed(error.localizedDescription) }
    }
}

struct SetupHost: View {
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        ZStack {
            switch setup.state {
            case .idle: EmptyView()
            case .working(let text):
                DialogPanel {
                    Text(L.setupTitle).font(DS.display(24)).foregroundStyle(DS.ink)
                    Text(text).font(DS.body).foregroundStyle(DS.soft).contentTransition(.interpolate)
                    ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 220)
                    Text(L.setupOffline).font(DS.label).foregroundStyle(DS.soft)
                }
                .transition(.opacity)
            case .done:
                DialogPanel(alignment: .leading) {
                    Text(L.setupDone).font(DS.display(24)).foregroundStyle(DS.ink)
                    VStack(alignment: .leading, spacing: 10) {
                        StepRowText(number: 1, text: L.setupStep1)
                        StepRowText(number: 2, text: L.setupStep2)
                        StepRowText(number: 3, text: L.waitingStep2)
                    }
                    PrimaryButton(title: L.understood) { setup.state = .idle }.padding(.top, 4)
                }
                .transition(.opacity)
            case .failed(let why):
                DialogPanel(alignment: .leading) {
                    Text(L.setupFailed).font(DS.display(24)).foregroundStyle(DS.ink)
                    Text(why).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.soft).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L.close) { setup.state = .idle }.buttonStyle(QuietButton())
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: setup.state)
        .onAppear { setup.runIfNeeded() }
    }
}
