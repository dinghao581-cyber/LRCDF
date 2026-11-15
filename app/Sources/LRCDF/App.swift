import SwiftUI

@main
struct LRCDFApp: App {
    @StateObject private var studio = Studio()

    var body: some Scene {
        Window("LRCDF", id: "main") {
            RootView()
                // the rights prompt, card and break reminder (Rights.swift); not in the way of a run that is going on
                .overlay { if studio.stage != .working && studio.stage != .paused { RightsHost() } }
                .overlay(SetupHost())           // the all-in-one app installs itself the first time (Setup.swift)
                .overlay(UpdateHost())          // updates, in parts (Updater.swift)
                .environmentObject(studio)
                .frame(minWidth: 760, minHeight: 620)       // below 1000 wide the controls become a paged bar (Views.swift)
                .preferredColorScheme(.dark)
                .onAppear { studio.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1376, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { Button(L.updateCheckNow + "…") { Task { await Updater.shared.check(manual: true) } } }
            CommandGroup(after: .help) { Button(L.rightsMenu) { RightsCenter.shared.openCard() } }
        }
        Settings { UpdateSettings() }
    }
}
