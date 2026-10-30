import Foundation

/// Reading the logs that coding agents leave on disk.
///
/// Claude Code writes every session to `~/.claude/projects/<project>/<id>.jsonl`,
/// Codex to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Both are append-only
/// JSON lines, so the newest state of a session is always at the end of its
/// file — reading the tail is enough, and nothing has to be configured in the
/// agents themselves.
///
/// Everything here is plain functions on value types: it runs off the main
/// thread, in `Task.detached`, and hands back `Sendable` results.
enum AgentLogs {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var claudeProjects: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("projects", isDirectory: true)
        }
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var codexSessions: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("sessions", isDirectory: true)
        }
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Where anything else can report itself: one JSON file per task.
    static var customFolder: URL { Support.directory("agents") }

    // MARK: - Files

    struct LogFile: Sendable {
        var url: URL
        var modified: Date
    }

    /// `.jsonl` files directly inside each subfolder of `root` (Claude's layout:
    /// one folder per project), modified after `since`.
    static func claudeFiles(since: Date) -> [LogFile] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [LogFile] = []
        for project in projects {
            // A folder untouched for longer than the window cannot hold a fresh
            // session, and skipping it saves listing hundreds of old ones.
            if let date = modified(project), date < since.addingTimeInterval(-86_400) { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let date = modified(file), date >= since {
                    result.append(LogFile(url: file, modified: date))
                }
            }
        }
        return result
    }

    /// Codex files from the last `days` day-folders, newest first.
    static func codexFiles(days: Int, since: Date? = nil) -> [LogFile] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var result: [LogFile] = []
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let folder = codexSessions
                .appendingPathComponent(String(format: "%04d", y), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", m), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", d), isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let date = modified(file) else { continue }
                if let since, date < since { continue }
                result.append(LogFile(url: file, modified: date))
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Reading

    /// The last complete lines of a file, at most `bytes` worth.
    static func tail(_ url: URL, bytes: Int = 384 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Started mid-line: the first piece is a fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    /// The first lines of a file — where the opening prompt lives.
    static func head(_ url: URL, bytes: Int = 96 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if data.count >= bytes, !lines.isEmpty { lines.removeLast() }
        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    // MARK: - Small helpers

    static func oneLine(_ text: String, max: Int = 140) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = precise.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
        if let n = number(value) {
            // Seconds or milliseconds since 1970.
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        return nil
    }

    static func basename(_ path: Any?) -> String {
        guard let path = path as? String, !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }
}
