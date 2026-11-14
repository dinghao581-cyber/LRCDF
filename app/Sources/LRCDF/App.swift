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
                .environmentObject(studio)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { studio.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) { Button("了解您拥有的权利…") { RightsCenter.shared.openCard() } }
        }
    }
}
