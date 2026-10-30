import SwiftUI

/// How much of each subscription is left, and when it comes back.
struct LimitsPane: View {
    @ObservedObject var limits: LimitsStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                claudeCard
                codexCard
                Text(verbatim: "Gemini, Grok, Perplexity и Cursor не отдают лимиты наружу — их тут не будет")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeCard: some View {
        card(title: "Claude", subtitle: "приложение, claude.ai и Claude Code", trailing: claudeTrailing) {
            switch limits.claudeState {
            case .notConnected:
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Возьму вход из Claude Code. macOS спросит доступ к связке ключей — нажми «Разрешить всегда».")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    pill("Подключить") { limits.connectClaude() }
                }
            case .loading where limits.claude == nil:
                Text(verbatim: "Загружаю…")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            case .failed(let message) where limits.claude == nil:
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        pill("Повторить") { limits.refresh(force: true) }
                        pill("Отключить") { limits.disconnectClaude() }
                    }
                }
            default:
                windows(limits.claude?.windows ?? [])
            }
        }
    }

    @ViewBuilder
    private var claudeTrailing: some View {
        if limits.claudeState != .notConnected, limits.claude != nil {
            Button { limits.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
        }
    }

    // MARK: - Codex

    @ViewBuilder
    private var codexCard: some View {
        let subtitle = [limits.codex?.plan.map { "ChatGPT \($0.capitalized)" }, limits.codex?.asOf.map { "данные " + Self.ago($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
        card(title: "Codex", subtitle: subtitle.isEmpty ? "лимиты ChatGPT для Codex" : subtitle, trailing: EmptyView()) {
            if let codex = limits.codex {
                windows(codex.windows)
            } else {
                Text(verbatim: "Запусти Codex хотя бы раз — лимиты берутся из его журнала")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - Pieces

    private func windows(_ windows: [LimitWindow]) -> some View {
        VStack(spacing: 7) {
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: window.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.85))
                        Spacer(minLength: 4)
                        if let resets = window.resets {
                            Text(verbatim: "сброс " + Self.until(resets))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(verbatim: "\(Int(window.used.rounded()))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Self.color(window.used))
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                    ProgressLine(fraction: window.used / 100, color: Self.color(window.used))
                }
            }
        }
    }

    private func card<Trailing: View, Content: View>(
        title: String,
        subtitle: String,
        trailing: Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.surfaceHover))
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
    }

    static func color(_ used: Double) -> Color {
        if used >= 85 { return Color(red: 1.0, green: 0.42, blue: 0.4) }
        if used >= 60 { return Color(red: 1.0, green: 0.75, blue: 0.3) }
        return Color(red: 0.4, green: 0.85, blue: 0.5)
    }

    static func until(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 60 { return "сейчас" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "через \(minutes) мин" }
        let hours = minutes / 60
        if hours < 24 { return "через \(hours) ч \(minutes % 60) мин" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 120 { return "сейчас" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ч назад" }
        return "\(Int(seconds / 86_400)) дн. назад"
    }
}
