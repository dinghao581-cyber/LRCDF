import Foundation

/// Keeps the folder of preview pictures from growing without end (main session, 2026-11-16): every photo ever looked
/// at leaves about 9 MB there, and the whole of a batch is now loaded at once. Above 3 GB the folders least recently
/// changed go first, until it is below 2 GB. Only photo folders directly inside previews/ are deleted - never the
/// folder itself, nothing outside it, and never one of the folders `keep` names (the batch on screen).
enum PreviewCache {
    static let limit: Int64 = 3_000_000_000
    static let target: Int64 = 2_000_000_000

    /// The one folder this may delete in: spelled out here, not taken from anything that could be empty.
    private static var base: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/LRCDF/previews", isDirectory: true).standardizedFileURL
    }
    /// What a photo's folder is called: Lightroom's id of the photo and the picture size ("<UUID>_2600").
    private static let name = try! NSRegularExpression(pattern: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}_[0-9]+$")

    /// Runs in the background; returns what was deleted (for the log), nothing when under the limit.
    @discardableResult
    static func trim(keep: Set<URL> = []) async -> [String] {
        let kept = Set(keep.map { $0.standardizedFileURL.path })
        return await Task.detached(priority: .utility) { trimNow(keep: kept) }.value
    }

    nonisolated private static func trimNow(keep: Set<String>) -> [String] {
        let fm = FileManager.default
        let root = base
        let rootPath = root.path
        guard rootPath.hasSuffix("/Library/Application Support/LRCDF/previews"), rootPath.count > 45,
              let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var folders: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for url in entries {
            let size = sizeOf(url)
            total += size
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            folders.append((url, values?.contentModificationDate ?? .distantPast, size))
        }
        guard total > limit else { return [] }
        var removed: [String] = []
        for folder in folders.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            let url = folder.url.standardizedFileURL
            let leaf = url.lastPathComponent
            guard url.deletingLastPathComponent().path == rootPath, url.path.hasPrefix(rootPath + "/"),
                  name.firstMatch(in: leaf, range: NSRange(leaf.startIndex..., in: leaf)) != nil,
                  !keep.contains(url.path) else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                total -= folder.size
                removed.append(leaf)
            }
        }
        return removed
    }

    /// The bytes of the files in a folder (or of one file).
    nonisolated private static func sizeOf(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let file as URL in walk {
            if let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { sum += Int64(v.fileSize ?? 0) }
        }
        return sum
    }
}
