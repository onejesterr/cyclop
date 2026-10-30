import AppKit
import Translation

/// The translate tab: DeepL when there is a key, Apple's on-device translator
/// otherwise — and also whenever DeepL cannot be reached, so the tab never
/// just stops working.
///
/// Direction: by default Russian goes to English and everything else to
/// Russian. A target picked in the pane overrides that.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    struct Language: Identifiable, Hashable, Sendable {
        /// Apple's identifier: "en", "zh-Hans".
        var id: String
        /// DeepL's `target_lang`.
        var deepL: String
        var name: String
    }

    /// What the target picker offers. Russian and English first.
    static let languages: [Language] = [
        Language(id: "en", deepL: "EN-US", name: "Английский"),
        Language(id: "ru", deepL: "RU", name: "Русский"),
        Language(id: "uk", deepL: "UK", name: "Украинский"),
        Language(id: "de", deepL: "DE", name: "Немецкий"),
        Language(id: "fr", deepL: "FR", name: "Французский"),
        Language(id: "es", deepL: "ES", name: "Испанский"),
        Language(id: "it", deepL: "IT", name: "Итальянский"),
        Language(id: "pt", deepL: "PT-BR", name: "Португальский"),
        Language(id: "pl", deepL: "PL", name: "Польский"),
        Language(id: "tr", deepL: "TR", name: "Турецкий"),
        Language(id: "zh-Hans", deepL: "ZH-HANS", name: "Китайский"),
        Language(id: "ja", deepL: "JA", name: "Японский"),
        Language(id: "ko", deepL: "KO", name: "Корейский"),
        Language(id: "ar", deepL: "AR", name: "Арабский"),
    ]

    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    struct Request: Equatable {
        var text: String
        var attempt: Int
        var target: String
    }

    enum Engine: String { case deepL = "DeepL", apple = "Apple" }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    @Published private(set) var needsDownload = false
    @Published private(set) var engine: Engine?
    /// Set when DeepL was tried and failed, so the result came from Apple.
    @Published private(set) var notice: String?
    /// What DeepL said the text was written in.
    @Published private(set) var detectedSource: String?

    /// "auto" or one of `languages`' ids.
    @Published var target: String = UserDefaults.standard.string(forKey: "translate.target") ?? "auto" {
        didSet { UserDefaults.standard.set(target, forKey: "translate.target") }
    }

    @Published private(set) var hasDeepLKey = DeepLKey.load() != nil

    private var attempt = 0

    var request: Request { Request(text: input, attempt: attempt, target: target) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { route(for: trimmed) }

    // MARK: - Direction

    static func isCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably.
    func route(for text: String) -> Route {
        let source = Self.isCyrillic(text) ? Self.russian : Self.english
        guard target != "auto" else {
            return source == Self.russian
                ? Route(source: Self.russian, target: Self.english)
                : Route(source: Self.english, target: Self.russian)
        }
        let chosen = Locale.Language(identifier: target)
        // Same script as the target (English into English): the text is
        // probably in the other of the two main languages.
        if chosen.languageCode == source.languageCode {
            return Route(source: source == Self.russian ? Self.english : Self.russian, target: chosen)
        }
        return Route(source: source, target: chosen)
    }

    var targetTitle: String {
        if target == "auto" { return Self.name(route.target) }
        return Self.languages.first { $0.id == target }?.name ?? target
    }

    var sourceTitle: String {
        if engine == .deepL, let detected = detectedSource {
            let code = detected.lowercased()
            return Self.languages.first { $0.deepL.lowercased().hasPrefix(code) }?.name
                ?? Self.name(Locale.Language(identifier: code))
        }
        return Self.name(route.source)
    }

    private func deepLTarget(for text: String) -> String {
        if target == "auto" { return Self.isCyrillic(text) ? "EN-US" : "RU" }
        return Self.languages.first { $0.id == target }?.deepL ?? "EN-US"
    }

    // MARK: - State

    func retry() { attempt += 1 }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
        notice = nil
        detectedSource = nil
    }

    func reset() {
        input = ""
        clear()
    }

    // MARK: - DeepL

    func saveDeepLKey(_ key: String) {
        DeepLKey.save(key)
        hasDeepLKey = DeepLKey.load() != nil
        retry()
    }

    func removeDeepLKey() {
        DeepLKey.remove()
        hasDeepLKey = false
        retry()
    }

    /// Returns true when DeepL produced the result. False means "use Apple".
    func runDeepL() async -> Bool {
        let text = trimmed
        guard !text.isEmpty, let key = DeepLKey.load() else { return false }
        switch await DeepL.translate(text, target: deepLTarget(for: text), key: key) {
        case .success(let translated, let detected):
            guard !Task.isCancelled else { return true }
            output = translated
            detectedSource = detected
            failure = nil
            needsDownload = false
            notice = nil
            engine = .deepL
            return true
        case .cancelled:
            return true
        case .failure(let message):
            guard !Task.isCancelled else { return true }
            notice = message
            return false
        }
    }

    // MARK: - Apple

    func run(_ session: sending TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            engine = .apple
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            detectedSource = nil
            failure = nil
            needsDownload = false
            engine = .apple
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openDeepLSignup() {
        guard let url = URL(string: "https://www.deepl.com/pro-api") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - DeepL API

enum DeepL {
    enum Outcome: Sendable {
        case success(String, String?)
        case cancelled
        case failure(String)
    }

    static func translate(_ text: String, target: String, key: String) async -> Outcome {
        // Free keys end in ":fx" and live on their own host.
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else { return .failure("URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": [text], "target_lang": target]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let first = (object["translations"] as? [[String: Any]])?.first,
                      let translated = first["text"] as? String else {
                    return .failure("DeepL ответил непонятно — перевёл Apple")
                }
                return .success(translated, first["detected_source_language"] as? String)
            case 403:
                return .failure("Ключ DeepL не подошёл — перевёл Apple")
            case 456:
                return .failure("Лимит DeepL на месяц исчерпан — перевёл Apple")
            case 429:
                return .failure("DeepL просит подождать — перевёл Apple")
            default:
                return .failure("DeepL ответил \(code) — перевёл Apple")
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failure("DeepL недоступен — перевёл Apple")
        }
    }
}

/// The key lives in its own file next to the config, readable only by the
/// user — not in `config.json`, which is meant to be copied between Macs.
enum DeepLKey {
    static var file: URL { Support.file("deepl.key") }

    static func load() -> String? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return remove() }
        try? clean.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}
