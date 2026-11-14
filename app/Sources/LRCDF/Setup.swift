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
        state = .working("正在准备…")
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
                panel {
                    ProgressView().controlSize(.large)
                    Text("第一次打开，正在安装").font(.system(size: 20, weight: .semibold))
                    Text(text).font(.system(size: 13)).foregroundStyle(Palette.soft)
                    Text("全部在这台电脑上完成，不需要联网。").font(.system(size: 12)).foregroundStyle(Palette.soft)
                }
            case .done:
                panel {
                    Text("安装好了").font(.system(size: 20, weight: .semibold))
                    Text("1. 打开 Lightroom Classic（已经开着的话，请退出再打开一次）。\n2. 在图库里选中要修的照片。\n3. 菜单 图库 → 增效工具额外信息 → 开始一键修图…")
                        .font(.system(size: 13)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
                    Button { setup.state = .idle } label: {
                        Text("知道了").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 9)
                            .background(Palette.glow, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }
            case .failed(let why):
                panel {
                    Text("安装没有完成").font(.system(size: 20, weight: .semibold))
                    Text(why).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.soft).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("关闭") { setup.state = .idle }.buttonStyle(GhostButton())
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: setup.state)
        .onAppear { setup.runIfNeeded() }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) { content() }
                .padding(32).frame(width: 480)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, lineWidth: 1))
        }
    }
}
