import SwiftUI

/// What the agents are doing: one card per running or just-finished task.
struct AgentsPane: View {
    @ObservedObject var agents: AgentStore
    @ObservedObject var privacy: PrivacyMode

    var body: some View {
        if agents.sessions.isEmpty {
            empty
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(agents.sessions) { session in
                        AgentCard(
                            session: session,
                            hidden: privacy.hides(.calendar, session.id)
                        )
                        .onTapGesture { privacy.toggle(session.id) }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(verbatim: "Сейчас никто не работает")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Text(verbatim: "Здесь появятся задачи Claude Code и Codex\nза последние 40 минут")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentCard: View {
    let session: AgentSession
    let hidden: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(status: session.status)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: session.agent)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    if !session.project.isEmpty {
                        Text(verbatim: "· " + session.project)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: statusWord + " · " + Self.age(session.updated))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(statusColor.opacity(0.9))
                }

                if !session.title.isEmpty {
                    Text(verbatim: hidden ? "••••••••••••" : session.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }

                if !session.detail.isEmpty {
                    Text(verbatim: hidden ? "••••••••" : session.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if session.stepsTotal > 0 {
                    HStack(spacing: 6) {
                        ProgressLine(fraction: Double(session.stepsDone) / Double(session.stepsTotal), color: statusColor)
                        Text(verbatim: "\(session.stepsDone)/\(session.stepsTotal)")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusWord: String {
        switch session.status {
        case .working: return "работает"
        case .waiting: return "ждёт"
        case .done: return "готово"
        case .error: return "ошибка"
        case .idle: return "стоит"
        }
    }

    private var statusColor: Color { AgentColors.color(session.status) }

    static func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "сейчас" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин" }
        return "\(Int(seconds / 3600)) ч"
    }
}

enum AgentColors {
    static func color(_ status: AgentSession.Status) -> Color {
        switch status {
        case .working: return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .waiting: return Color(red: 1.0, green: 0.75, blue: 0.3)
        case .done: return Color(red: 0.4, green: 0.85, blue: 0.5)
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.4)
        case .idle: return Theme.secondary
        }
    }
}

private struct StatusDot: View {
    let status: AgentSession.Status
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(AgentColors.color(status))
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(AgentColors.color(status).opacity(status == .working ? 0.6 : 0), lineWidth: 1.5)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear { animate() }
            .onChange(of: status) { _, _ in animate() }
    }

    private func animate() {
        pulse = false
        guard status == .working else { return }
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
    }
}

struct ProgressLine: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHover)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
