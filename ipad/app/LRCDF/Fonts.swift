import CoreText
import SwiftUI

/// 宋体 (Songti SC) for the titles, as on the Mac (DS.display). Apple's font licence does not allow shipping it inside
/// the app, but iPadOS can fetch it from Apple's own font servers (a "downloadable system font"): done once, kept by
/// the system, available offline afterwards. Until then the titles use the system face. Fetched only while
/// "自动检查新版本" is on - with it off the app does not go online at all (user 2026-11-15: "向苹果下载宋体").
@MainActor
final class Fonts: ObservableObject {
    static let shared = Fonts()
    @Published private(set) var songti = Fonts.has()
    private var asked = false

    nonisolated static func has() -> Bool { (CTFontCopyPostScriptName(CTFontCreateWithName("STSongti-SC-Bold" as CFString, 20, nil)) as String) == "STSongti-SC-Bold" }

    func fetchIfAllowed() {
        guard !songti, !asked, UpdateNotice.shared.enabled else { return }
        asked = true
        let want = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "STSongti-SC-Bold"] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([want] as CFArray, nil) { state, _ in
            if state == .didFinish {
                Task { @MainActor in Fonts.shared.songti = Fonts.has() }
            }
            return true
        }
    }
}
