import Foundation

/// Talks to the Lightroom plug-in through a shared folder: a command is a small text file, the answer another one.
enum Bridge {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LRCDF", isDirectory: true)
    static var commands: URL { root.appendingPathComponent("cmd", isDirectory: true) }
    static var session: URL { root.appendingPathComponent("session.json") }
    static var progress: URL { root.appendingPathComponent("progress.txt") }
    static var previews: URL { root.appendingPathComponent("previews", isDirectory: true) }
    static var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    static var before: URL { root.appendingPathComponent("before", isDirectory: true) }     // photos as they were (1400 px)
    static var after: URL { root.appendingPathComponent("after", isDirectory: true) }       // finished pictures (1400 px)
    static var undo: URL { root.appendingPathComponent("undo", isDirectory: true) }         // settings saved before a run
    static var run: URL { root.appendingPathComponent("run.json") }                         // the run in progress or the last one

    enum Failure: LocalizedError {
        case lightroomAway, refused(String), noAnswer
        var errorDescription: String? {
            switch self {
            case .lightroomAway: return "没有连上 Lightroom。请先打开 Lightroom Classic。"
            case .refused(let why): return why
            case .noAnswer: return "Lightroom 没有回应，请回到 Lightroom 看看是否有对话框挡住了。"
            }
        }
    }

    /// The plug-in writes the time into this file a few times a second while Lightroom is open.
    static func lightroomIsOpen() -> Bool {
        guard let text = try? String(contentsOf: commands.appendingPathComponent("alive"), encoding: .utf8),
              let stamp = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return Date().timeIntervalSince1970 - stamp < 8
    }

    private static let lock = NSLock()
    private static var waiting = 0
    private static func count(_ change: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        waiting += change
        return waiting
    }

    /// Sends one command and waits for its answer (the lines after "ok").
    static func send(_ arguments: [(String, String)], timeout: TimeInterval) async throws -> [String] {
        // The plug-in works on one command at a time and cannot write its sign of life meanwhile. So silence only
        // means "Lightroom is closed" when nothing of ours is being worked on.
        guard count(0) > 0 || lightroomIsOpen() else { throw Failure.lightroomAway }
        _ = count(1)
        defer { _ = count(-1) }
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        // the time keeps commands in order, the random part keeps two sent in the same instant apart
        let name = "app\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        let draft = commands.appendingPathComponent(name + ".tmp")
        let command = commands.appendingPathComponent(name + ".cmd")
        let answer = commands.appendingPathComponent(name + ".done")
        try arguments.map { "\($0.0)=\($0.1)" }.joined(separator: "\n").appending("\n")
            .write(to: draft, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: draft, to: command)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: answer, encoding: .utf8), text.hasSuffix("\n") {
                try? FileManager.default.removeItem(at: answer)
                var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                let verdict = lines.isEmpty ? "" : lines.removeFirst()
                if verdict == "ok" { return lines }
                throw Failure.refused(lines.joined(separator: "\n"))
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try? FileManager.default.removeItem(at: command)
        throw Failure.noAnswer
    }
}
