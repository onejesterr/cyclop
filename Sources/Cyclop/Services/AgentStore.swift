import Foundation

/// One task one agent is running (or has just finished).
struct AgentSession: Identifiable, Equatable, Sendable {
    enum Status: Int, Sendable, Comparable {
        case working = 0, waiting, error, done, idle
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var agent: String
    var project: String
    var title: String
    var status: Status
    var detail: String
    var stepsDone = 0
    var stepsTotal = 0
    var updated: Date
}

/// What every agent is doing right now, read from the agents' own logs.
///
/// Polls only while the panel is open: nobody sees the list otherwise, and a
/// scan is a handful of directory listings plus the tail of a few files.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?
    private var isActive = false
    private var isRunning = false
    private var scanning = false

    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    func start() {
        isRunning = true
        refresh()
    }

    func stop() {
        isRunning = false
        stopTimer()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active && isRunning {
            refresh()
            startTimer()
        } else {
            stopTimer()
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            let now = Date()
            let found = await Task.detached(priority: .utility) {
                AgentScanner.scan(now: now)
            }.value
            self.scanning = false
            if found != self.sessions { self.sessions = found }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Scanning

enum AgentScanner {
    /// How far back a session still counts as "recent".
    static let window: TimeInterval = 40 * 60

    static func scan(now: Date) -> [AgentSession] {
        let since = now.addingTimeInterval(-window)
        var result: [AgentSession] = []

        let claude = AgentLogs.claudeFiles(since: since)
            .sorted { $0.modified > $1.modified }
            .prefix(8)
        for file in claude {
            if let session = claudeSession(file, now: now) { result.append(session) }
        }

        for file in AgentLogs.codexFiles(days: 2, since: since).prefix(6) {
            if let session = codexSession(file, now: now) { result.append(session) }
        }

        result.append(contentsOf: customSessions(since: since))

        // Working first, then the ones waiting for a person, then the rest by age.
        return result.sorted {
            if $0.status != $1.status { return $0.status < $1.status }
            return $0.updated > $1.updated
        }
    }

    // MARK: Shared state machine

    private enum Last {
        case none
        case prompt
        case toolResult
        case text(String)
        case tool(name: String, detail: String)
        case finished
        case failed(String)
    }

    private struct Steps {
        var done = 0
        var total = 0
        var current: String?
    }

    private static func classify(_ last: Last, age: TimeInterval, tool waitingAfter: TimeInterval)
        -> (AgentSession.Status, String)
    {
        switch last {
        case .none:
            return (.idle, "")
        case .prompt, .toolResult:
            return age < 300 ? (.working, "Думает…") : (.idle, "Остановлен")
        case .text(let text):
            return age < 6 ? (.working, "Пишет ответ…") : (.done, text.isEmpty ? "Готово" : text)
        case .tool(let name, let detail):
            if name == "AskUserQuestion" || name == "ExitPlanMode" || name == "request_user_input" {
                return (.waiting, "Ждёт твоего ответа")
            }
            if age < waitingAfter { return (.working, detail) }
            return age < 1800 ? (.waiting, "Ждёт разрешения или долго выполняет: \(detail)") : (.idle, detail)
        case .finished:
            return (.done, "Готово")
        case .failed(let message):
            return (.error, message)
        }
    }

    // MARK: Claude Code

    static func claudeSession(_ file: AgentLogs.LogFile, now: Date) -> AgentSession? {
        let lines = AgentLogs.tail(file.url)
        guard !lines.isEmpty else { return nil }

        var last = Last.none
        var cwd: String?
        var steps = Steps()
        var isSidechain = false

        for line in lines {
            if let c = line["cwd"] as? String { cwd = c }
            if let side = line["isSidechain"] as? Bool { isSidechain = side }
            let type = line["type"] as? String
            guard let message = line["message"] as? [String: Any] else { continue }
            if type == "user" {
                if (line["isMeta"] as? Bool) == true { continue }
                if let text = message["content"] as? String {
                    if isPrompt(text) { last = .prompt }
                } else if let items = message["content"] as? [[String: Any]] {
                    if items.contains(where: { $0["type"] as? String == "tool_result" }) {
                        last = .toolResult
                    } else if let text = items.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                              isPrompt(text) {
                        last = .prompt
                    }
                }
            } else if type == "assistant", let items = message["content"] as? [[String: Any]] {
                for item in items {
                    switch item["type"] as? String {
                    case "text":
                        let text = AgentLogs.oneLine(item["text"] as? String ?? "")
                        if !text.isEmpty { last = .text(text) }
                    case "tool_use":
                        let name = item["name"] as? String ?? "tool"
                        let input = item["input"] as? [String: Any] ?? [:]
                        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                            steps = Self.steps(todos, key: "content", active: "activeForm")
                        }
                        last = .tool(name: name, detail: describeClaude(name, input, steps: steps))
                    default:
                        break
                    }
                }
            }
        }
        // Subagent transcripts are shown through their parent.
        if isSidechain { return nil }

        let age = now.timeIntervalSince(file.modified)
        var (status, detail) = classify(last, age: age, tool: 25)
        if status == .idle && age > 600 { return nil }
        if status == .working, let current = steps.current, case .prompt = last { detail = current }

        let project = cwd.map { ($0 as NSString).lastPathComponent } ?? projectName(from: file.url)
        return AgentSession(
            id: "claude-" + file.url.deletingPathExtension().lastPathComponent,
            agent: "Claude Code",
            project: project,
            title: claudeTitle(file.url),
            status: status,
            detail: detail,
            stepsDone: steps.done,
            stepsTotal: steps.total,
            updated: file.modified
        )
    }

    private static func isPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-command echoes, hook output and caveats are wrapped in tags.
        return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("Caveat:") && !t.hasPrefix("[Request interrupted")
    }

    private static func claudeTitle(_ url: URL) -> String {
        var summary: String?
        for line in AgentLogs.head(url) {
            if line["type"] as? String == "summary", let s = line["summary"] as? String { summary = s }
            guard line["type"] as? String == "user", (line["isMeta"] as? Bool) != true,
                  let message = line["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String, isPrompt(text) { return AgentLogs.oneLine(text, max: 90) }
            if let items = message["content"] as? [[String: Any]],
               !items.contains(where: { $0["type"] as? String == "tool_result" }),
               let text = items.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
               isPrompt(text) {
                return AgentLogs.oneLine(text, max: 90)
            }
        }
        return summary ?? ""
    }

    /// `-Users-me-Projects-site` → `site`.
    private static func projectName(from url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder.split(separator: "-").last.map(String.init) ?? folder
    }

    private static func describeClaude(_ name: String, _ input: [String: Any], steps: Steps) -> String {
        switch name {
        case "Bash":
            return "$ " + AgentLogs.oneLine(input["description"] as? String ?? input["command"] as? String ?? "", max: 80)
        case "Read":
            return "Читает " + AgentLogs.basename(input["file_path"])
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return "Правит " + AgentLogs.basename(input["file_path"] ?? input["notebook_path"])
        case "Grep":
            return "Ищет «\(AgentLogs.oneLine(input["pattern"] as? String ?? "", max: 40))»"
        case "Glob":
            return "Ищет файлы \(input["pattern"] as? String ?? "")"
        case "WebSearch":
            return "Ищет в сети «\(AgentLogs.oneLine(input["query"] as? String ?? "", max: 50))»"
        case "WebFetch":
            let host = URL(string: input["url"] as? String ?? "")?.host ?? ""
            return "Открывает \(host)"
        case "Task", "Agent":
            return "Субагент: " + AgentLogs.oneLine(input["description"] as? String ?? "", max: 60)
        case "TodoWrite":
            return steps.current ?? "Обновляет план"
        default:
            // mcp__server__tool → tool
            let short = name.split(separator: "_").last.map(String.init) ?? name
            return name.hasPrefix("mcp__") ? "Инструмент: \(short)" : name
        }
    }

    // MARK: Codex

    static func codexSession(_ file: AgentLogs.LogFile, now: Date) -> AgentSession? {
        let lines = AgentLogs.tail(file.url)
        guard !lines.isEmpty else { return nil }

        var last = Last.none
        var cwd: String?
        var steps = Steps()

        for line in lines {
            let type = line["type"] as? String
            guard let payload = line["payload"] as? [String: Any] else { continue }
            let kind = payload["type"] as? String
            if let c = payload["cwd"] as? String { cwd = c }

            switch (type, kind) {
            case ("response_item", "message"):
                let role = payload["role"] as? String
                let text = codexText(payload["content"])
                if role == "user", isPrompt(text) { last = .prompt }
                if role == "assistant", !text.isEmpty { last = .text(AgentLogs.oneLine(text)) }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = payload["name"] as? String ?? "tool"
                let raw = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
                let args = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                if name == "update_plan", let plan = args["plan"] as? [[String: Any]] {
                    steps = Self.steps(plan, key: "step", active: nil)
                }
                last = .tool(name: name, detail: describeCodex(name, args, raw: raw, steps: steps))
            case ("response_item", "local_shell_call"):
                let action = payload["action"] as? [String: Any] ?? [:]
                let command = (action["command"] as? [String])?.joined(separator: " ") ?? ""
                last = .tool(name: "shell", detail: "$ " + AgentLogs.oneLine(command, max: 80))
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                last = .toolResult
            case ("event_msg", "user_message"):
                last = .prompt
            case ("event_msg", "agent_message"):
                last = .text(AgentLogs.oneLine(payload["message"] as? String ?? ""))
            case ("event_msg", "task_complete"):
                if let message = payload["last_agent_message"] as? String, !message.isEmpty {
                    last = .text(AgentLogs.oneLine(message))
                } else {
                    last = .finished
                }
            case ("event_msg", "turn_aborted"):
                last = .finished
            case ("event_msg", "error"), ("event_msg", "stream_error"):
                last = .failed(AgentLogs.oneLine(payload["message"] as? String ?? "Ошибка"))
            default:
                break
            }
        }

        let age = now.timeIntervalSince(file.modified)
        let (status, detail) = classify(last, age: age, tool: 60)
        if status == .idle && age > 600 { return nil }

        return AgentSession(
            id: "codex-" + file.url.deletingPathExtension().lastPathComponent,
            agent: "Codex",
            project: cwd.map { ($0 as NSString).lastPathComponent } ?? "",
            title: codexTitle(file.url),
            status: status,
            detail: detail,
            stepsDone: steps.done,
            stepsTotal: steps.total,
            updated: file.modified
        )
    }

    private static func codexText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func codexTitle(_ url: URL) -> String {
        for line in AgentLogs.head(url) {
            guard let payload = line["payload"] as? [String: Any] else { continue }
            if line["type"] as? String == "event_msg", payload["type"] as? String == "user_message",
               let text = payload["message"] as? String, isPrompt(text) {
                return AgentLogs.oneLine(text, max: 90)
            }
            if payload["type"] as? String == "message", payload["role"] as? String == "user" {
                let text = codexText(payload["content"])
                if isPrompt(text) { return AgentLogs.oneLine(text, max: 90) }
            }
        }
        return ""
    }

    private static func describeCodex(_ name: String, _ args: [String: Any], raw: String, steps: Steps) -> String {
        switch name {
        case "shell", "exec_command", "container.exec":
            let command = (args["command"] as? [String])?.joined(separator: " ")
                ?? args["cmd"] as? String ?? args["command"] as? String ?? ""
            return "$ " + AgentLogs.oneLine(command, max: 80)
        case "apply_patch":
            let file = raw.components(separatedBy: "\n")
                .first { $0.hasPrefix("*** Update File: ") || $0.hasPrefix("*** Add File: ") }
                .map { ($0.components(separatedBy: ": ").last ?? "") as NSString }?
                .lastPathComponent
            return "Правит " + (file ?? "файлы")
        case "update_plan":
            return steps.current ?? "Обновляет план"
        case "web_search":
            return "Ищет в сети"
        default:
            return name
        }
    }

    // MARK: Plans

    private static func steps(_ items: [[String: Any]], key: String, active: String?) -> Steps {
        var steps = Steps()
        steps.total = items.count
        for item in items {
            let status = item["status"] as? String ?? ""
            if status == "completed" { steps.done += 1 }
            if status == "in_progress", steps.current == nil {
                let text = (active.flatMap { item[$0] as? String }) ?? item[key] as? String ?? ""
                steps.current = AgentLogs.oneLine(text, max: 80)
            }
        }
        return steps
    }

    // MARK: Anything else

    /// `~/Library/Application Support/Cyclop/agents/*.json`:
    /// `{"agent": "Hermes", "title": "…", "status": "working|waiting|done|error",
    ///   "detail": "…", "done": 2, "total": 5, "project": "…"}`.
    /// Any agent with hooks — or a two-line script — can report this way.
    private struct Custom: Decodable {
        var agent: String?
        var title: String?
        var status: String?
        var detail: String?
        var done: Int?
        var total: Int?
        var project: String?
    }

    private static func customSessions(since: Date) -> [AgentSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AgentLogs.customFolder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let modified = AgentLogs.modified(url), modified >= since,
                  let data = try? Data(contentsOf: url),
                  let custom = try? JSONDecoder().decode(Custom.self, from: data) else { return nil }
            let status: AgentSession.Status
            switch custom.status?.lowercased() {
            case "waiting": status = .waiting
            case "done", "finished", "completed": status = .done
            case "error", "failed": status = .error
            case "idle": status = .idle
            default: status = .working
            }
            return AgentSession(
                id: "custom-" + url.deletingPathExtension().lastPathComponent,
                agent: custom.agent ?? url.deletingPathExtension().lastPathComponent,
                project: custom.project ?? "",
                title: custom.title ?? "",
                status: status,
                detail: custom.detail ?? "",
                stepsDone: custom.done ?? 0,
                stepsTotal: custom.total ?? 0,
                updated: modified
            )
        }
    }
}
