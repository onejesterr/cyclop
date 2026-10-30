import Foundation
import Security

struct LimitWindow: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    /// 0…100.
    var used: Double
    var resets: Date?
}

struct ProviderLimits: Equatable, Sendable {
    var windows: [LimitWindow]
    var plan: String?
    /// When these numbers were true. For Codex that is the last time Codex
    /// itself ran, not when the panel looked.
    var asOf: Date?
}

/// Subscription limits of the AI tools that expose them.
///
/// **Claude** (the app, claude.ai and Claude Code share one allowance): asked
/// from Anthropic with the login Claude Code keeps in the keychain. Read only
/// after the user presses the button — macOS asks once whether Cyclop may use
/// that keychain item. The token is never refreshed here: refreshing rotates
/// it and would sign Claude Code out.
///
/// **Codex** (ChatGPT Plus/Pro): every Codex session log records the current
/// rate limits, so the newest log has the newest numbers, no login needed.
@MainActor
final class LimitsStore: ObservableObject {
    enum ClaudeState: Equatable {
        case notConnected
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var claude: ProviderLimits?
    @Published private(set) var claudeState: ClaudeState
    @Published private(set) var codex: ProviderLimits?

    private static let connectedKey = "limits.claudeConnected"
    private var token: String?
    private var lastClaudeFetch: Date?
    private var timer: Timer?
    private var isRunning = false

    init() {
        claudeState = UserDefaults.standard.bool(forKey: Self.connectedKey) ? .loading : .notConnected
    }

    var headline: String? {
        let values = (claude?.windows.first.map { ["Claude \(Int($0.used.rounded()))%"] } ?? [])
            + (codex?.windows.first.map { ["Codex \(Int($0.used.rounded()))%"] } ?? [])
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    func start() { isRunning = true }

    func stop() {
        isRunning = false
        setActive(false)
    }

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active, isRunning else { return }
        refresh(force: false)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func connectClaude() {
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        claudeState = .loading
        refresh(force: true)
    }

    func disconnectClaude() {
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        token = nil
        claude = nil
        claudeState = .notConnected
    }

    func refresh(force: Bool) {
        Task {
            let found = await Task.detached(priority: .utility) { CodexLimits.read() }.value
            if found != self.codex { self.codex = found }
        }
        guard claudeState != .notConnected else { return }
        if !force, let last = lastClaudeFetch, Date().timeIntervalSince(last) < 120 { return }
        lastClaudeFetch = Date()
        Task { await fetchClaude(retrying: true) }
    }

    private func fetchClaude(retrying: Bool) async {
        if token == nil {
            token = await Task.detached(priority: .userInitiated) { ClaudeCredentials.accessToken() }.value
        }
        guard let token else {
            claudeState = .failed("Не нашёл вход Claude Code. Запусти `claude` в терминале и войди в аккаунт.")
            return
        }
        switch await ClaudeUsage.fetch(token: token) {
        case .success(let limits):
            claude = limits
            claudeState = .ready
        case .unauthorized:
            // Claude Code may have refreshed its token since we read it.
            self.token = nil
            if retrying {
                await fetchClaude(retrying: false)
            } else {
                claudeState = .failed("Вход устарел. Открой Claude Code — он обновит его сам, потом обнови здесь.")
            }
        case .failure(let message):
            if claude == nil { claudeState = .failed(message) }
        }
    }
}

// MARK: - Claude

enum ClaudeCredentials {
    /// Claude Code keeps `{"claudeAiOauth": {"accessToken": …}}` in the
    /// keychain on macOS, and in a file on other systems or older versions.
    static func accessToken() -> String? {
        let file = AgentLogs.home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = parse(data) { return token }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}

enum ClaudeUsage {
    enum Outcome: Sendable {
        case success(ProviderLimits)
        case unauthorized
        case failure(String)
    }

    static func fetch(token: String) async -> Outcome {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return .failure("URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unauthorized }
            guard code == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("Anthropic ответил \(code)")
            }
            return .success(parse(object))
        } catch {
            return .failure("Нет связи с Anthropic")
        }
    }

    private static let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    static func parse(_ object: [String: Any]) -> ProviderLimits {
        var windows: [LimitWindow] = []
        for (key, value) in object {
            guard let entry = value as? [String: Any],
                  let used = AgentLogs.number(entry["utilization"]) else { continue }
            windows.append(LimitWindow(
                id: key,
                label: label(key),
                used: min(max(used, 0), 100),
                resets: AgentLogs.date(entry["resets_at"])
            ))
        }
        windows.sort {
            let a = order.firstIndex(of: $0.id) ?? 99, b = order.firstIndex(of: $1.id) ?? 99
            return a != b ? a < b : $0.id < $1.id
        }
        return ProviderLimits(windows: windows, plan: nil, asOf: Date())
    }

    private static func label(_ key: String) -> String {
        switch key {
        case "five_hour": return "Сессия · 5 часов"
        case "seven_day": return "Неделя · все модели"
        case "seven_day_sonnet": return "Неделя · Sonnet"
        case "seven_day_opus": return "Неделя · Opus"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Codex

enum CodexLimits {
    /// The newest `rate_limits` any Codex session has logged in the last week.
    static func read() -> ProviderLimits? {
        for file in AgentLogs.codexFiles(days: 8).prefix(12) {
            if let limits = fromFile(file.url) { return limits }
        }
        return nil
    }

    private static func fromFile(_ url: URL) -> ProviderLimits? {
        for line in AgentLogs.tail(url, bytes: 512 * 1024).reversed() {
            guard let payload = line["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let stamp = AgentLogs.date(line["timestamp"]) ?? AgentLogs.modified(url) ?? Date()
            var windows: [LimitWindow] = []
            for key in ["primary", "secondary"] {
                guard let entry = limits[key] as? [String: Any],
                      let used = AgentLogs.number(entry["used_percent"]) else { continue }
                let minutes = AgentLogs.number(entry["window_minutes"])
                var resets: Date?
                if let at = entry["resets_at"] {
                    resets = AgentLogs.date(at)
                } else if let seconds = AgentLogs.number(entry["resets_in_seconds"]) {
                    resets = stamp.addingTimeInterval(seconds)
                }
                // A window that has rolled over since the log was written is
                // empty now, whatever the log says.
                let current = (resets.map { $0 < Date() } ?? false) ? 0 : used
                windows.append(LimitWindow(
                    id: key,
                    label: label(minutes, fallback: key),
                    used: min(max(current, 0), 100),
                    resets: (resets.map { $0 < Date() } ?? false) ? nil : resets
                ))
            }
            guard !windows.isEmpty else { continue }
            let plan = limits["plan_type"] as? String
            return ProviderLimits(windows: windows, plan: plan, asOf: stamp)
        }
        return nil
    }

    private static func label(_ minutes: Double?, fallback: String) -> String {
        guard let minutes else { return fallback == "primary" ? "Сессия" : "Неделя" }
        switch Int(minutes) {
        case 300: return "Сессия · 5 часов"
        case 10_080: return "Неделя"
        case let m where m >= 1440: return "\(m / 1440) дн."
        case let m: return "\(m / 60) ч"
        }
    }
}
