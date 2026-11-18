import SwiftUI

/// The licence texts that travel with the app (Contents/Resources/licenses, put there by app/copy_licenses.sh).
/// They are shown exactly as they are: never translated, never reformatted.
enum Licences {
    static let files = ["APPLE_ML_RESEARCH_MODEL_LICENSE.txt", "MODEL_LICENSES.md", "THIRD_PARTY_NOTICES.md", "NOTICE", "LICENSE"]
    /// Required wording: the same in every language.
    static let notice = "Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement."
    static let windowID = "licences"

    static func text(of name: String) -> String {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("licenses"),
              let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return "File not found." }
        return text
    }
}

/// The read-only window: a row of file names at the top, every file below it under its own heading.
struct LicencesView: View {
    private let sections = Licences.files.map { (name: $0, text: Licences.text(of: $0)) }

    var body: some View {
        ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: DS.gap) {
                Text(L.licences).font(DS.display(24)).foregroundStyle(DS.ink).padding(.top, 34).padding(.horizontal, 6)
                LicenceRow(spacing: 8) {
                    ForEach(sections, id: \.name) { section in
                        Button(section.name) { withAnimation(DS.pick) { reader.scrollTo(section.name, anchor: .top) } }
                            .buttonStyle(QuietButton())
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.name) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(verbatim: section.name).font(DS.section).foregroundStyle(DS.ink)
                                Text(verbatim: section.text).font(DS.body).foregroundStyle(DS.soft).lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.pad)       // a jump leaves the heading clear of the panel's edge
                            .id(section.name)
                        }
                    }
                    .padding([.horizontal, .bottom], DS.pad)
                }
                .glass(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: DS.panel, style: .continuous))
            }
            .padding(DS.gap)
            #if DEBUG
            .task {
                guard let jump = ProcessInfo.processInfo.environment["LRCDF_LICENCE"], let at = Int(jump) else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                reader.scrollTo(sections[at].name, anchor: .top)
            }
            #endif
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Lays its children out in rows, starting a new row when one does not fit.
private struct LicenceRow: Layout {
    var spacing: CGFloat

    private func rows(_ width: CGFloat, _ views: Subviews) -> [(views: [(LayoutSubview, CGSize)], height: CGFloat)] {
        var result: [(views: [(LayoutSubview, CGSize)], height: CGFloat)] = [([], 0)]
        var x: CGFloat = 0
        for view in views {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { result.append(([], 0)); x = 0 }
            result[result.count - 1].views.append((view, size))
            result[result.count - 1].height = max(result[result.count - 1].height, size.height)
            x += size.width + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let all = rows(width, subviews)
        return CGSize(width: width, height: all.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, all.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for (view, size) in row.views {
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}

extension View {
    /// Debug builds: LRCDF_WINDOW=settings or licences opens that window at launch, for screenshots.
    @ViewBuilder func debugWindows() -> some View {
        #if DEBUG
        modifier(DebugWindows())
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugWindows: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.task {
            switch ProcessInfo.processInfo.environment["LRCDF_WINDOW"] {
            case "licences": openWindow(id: Licences.windowID)
            case "settings": openSettings()
            default: break
            }
        }
    }
}
#endif
