import SwiftUI
import Translation

/// Two columns, the way every translator is laid out: source on the left,
/// result on the right. The left one sits on a surface — that is the whole
/// signal that it can be typed into, since a caret only shows up once there
/// is something in it.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool
    @FocusState private var keyFocused: Bool
    /// What the pane shows instead of the two columns, if anything.
    @State private var mode: Mode = .translate
    @State private var keyDraft = ""

    private enum Mode { case translate, pickLanguage, key }
    @State private var configuration: TranslationSession.Configuration?
    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero

    /// Largest first. Four rungs, far enough apart that a change is always a
    /// deliberate-looking drop rather than a wobble.
    private let ladder: [CGFloat] = [27, 20, 15, 11]

    var body: some View {
        let font = fontSize(in: paneSize)
        ZStack {
            HStack(alignment: .top, spacing: 10) {
                source(font)
                result(font)
            }
            .opacity(mode == .translate ? 1 : 0)
            .allowsHitTesting(mode == .translate)

            if mode == .pickLanguage { languagePicker }
            if mode == .key { keyEntry }
        }
        .animation(Theme.contentAnimation, value: mode)
        // Measured from a background layer rather than by wrapping the content
        // in a GeometryReader. Wrapped, the type size depends on a measurement
        // that depends on the very text being sized, so every wrap onto a new
        // line costs a second layout pass — which is exactly the hitch one sees
        // at the moment a line breaks. The panel never changes size, so this
        // reads once and then stays put.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in paneSize = new }
            }
        )
        .padding(.top, 2)
        // One task for both the text and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: translator.request) { await schedule() }
        .translationTask(configuration) { session in
            await translator.run(session)
        }
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in
            if mode == .key { keyFocused = wants } else { focused = wants }
        }
    }

    // MARK: - Left

    private func source(_ font: CGFloat) -> some View {
        column(translator.sourceTitle) {
            Button { openKeyEntry() } label: {
                Image(systemName: translator.hasDeepLKey ? "key.fill" : "key")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(translator.hasDeepLKey ? Theme.secondary : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .help(translator.hasDeepLKey ? "Ключ DeepL" : "Подключить DeepL")
            if !translator.input.isEmpty {
                Button { translator.reset() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
            }
        } content: {
            // A `TextField(axis: .vertical)` grows to fit its text, and growing
            // means reporting a new intrinsic size, which invalidates layout
            // all the way to the root of the panel — once per wrapped line,
            // which is precisely when the hitch showed. An editor takes the
            // rectangle it is given and re-wraps inside it, so a new line
            // costs nothing outside its own bounds.
            TextEditor(text: $translator.input)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: font))
                .foregroundStyle(.white)
                // Grey rather than the system accent: the caret has to say
                // where typing lands without being the brightest thing in a
                // panel that is mostly dark and mostly still.
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the title.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onKeyPress(.escape) {
                    translator.reset()
                    return .handled
                }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Right

    private func result(_ font: CGFloat) -> some View {
        column(translator.targetTitle, onTitleTap: { mode = .pickLanguage }) {
            if let engine = translator.engine, !translator.output.isEmpty {
                Text(verbatim: engine.rawValue)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(engine == .deepL ? Theme.secondary : Theme.tertiary)
                    .help(translator.notice ?? "")
            }
            if !translator.output.isEmpty {
                CopyButton { translator.copyOutput() }
            }
        } content: {
            outcome(font)
        }
        .padding(10)
    }

    @ViewBuilder
    private func outcome(_ font: CGFloat) -> some View {
        if let failure = translator.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if translator.needsDownload {
                        Button("Translation Languages…") { Translator.openLanguageSettings() }
                    }
                    Button("Retry") { translator.retry() }
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !translator.output.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(translator.output)
                    .font(.system(size: font))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Nothing while it works. The translation lands in a fraction of a
            // second, so a status would be a word that flashes up and leaves —
            // more movement in the column than the result it announces.
            Color.clear
        }
    }

    // MARK: - Type size
    //
    // A word should read like a headline and a paragraph has to fit, so the
    // size has to move — but it moves in steps, not continuously. Sizing the
    // type to the exact text length means every keystroke re-breaks every line
    // for a fraction of a point nobody asked for, and that reads as the text
    // shaking rather than as anything smooth. One decisive drop, rarely, is
    // both calmer to look at and easier to trust.

    /// What the text actually gets to occupy inside one column: half the pane
    /// minus the gap, minus the padding, minus the title row above it.
    private func textArea(in size: CGSize) -> CGSize {
        CGSize(
            width: max(40, (size.width - 10) / 2 - 20),
            height: max(40, size.height - 40)
        )
    }

    /// The largest rung the text still fits on. Both columns share it, computed
    /// from whichever side is longer — sides set at different scales stop
    /// looking like a pair.
    private func fontSize(in size: CGSize) -> CGFloat {
        let count = CGFloat(max(translator.trimmed.count, translator.output.count))
        // Before the first measurement lands there is nothing to fit type to,
        // and the pane is empty anyway.
        guard count > 0, size.width > 0, size.height > 0 else { return ladder[0] }
        // A glyph runs about half its point size wide and 1.3 of it tall with
        // leading, so roughly `area / (0.76 · s²)` characters fit at size `s`.
        // The 0.95 keeps the last line from being the one that overflows.
        let area = textArea(in: size)
        let usable = area.width * area.height * 0.95
        return ladder.first { count <= usable / (0.76 * $0 * $0) } ?? ladder[ladder.count - 1]
    }

    // MARK: - Shared

    private func column<Accessory: View, Content: View>(
        _ title: String,
        onTitleTap: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let onTitleTap {
                    Button(action: onTitleTap) {
                        HStack(spacing: 3) {
                            Text(verbatim: title.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.8)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surface))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.default)
                    .padding(.leading, -6)
                } else {
                    Text(verbatim: title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 4)
                accessory()
            }
            .frame(height: 14)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Language picker

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "ПЕРЕВОДИТЬ НА")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                closeButton
            }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    chip("Авто: RU ↔ EN", selected: translator.target == "auto") { pick("auto") }
                    ForEach(Translator.languages) { language in
                        chip(language.name, selected: translator.target == language.id) { pick(language.id) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white : Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
    }

    private func pick(_ id: String) {
        translator.target = id
        mode = .translate
        focused = wantsKeyboard
    }

    private var closeButton: some View {
        Button {
            mode = .translate
            focused = wantsKeyboard
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
    }

    // MARK: - DeepL key

    private func openKeyEntry() {
        keyDraft = ""
        mode = .key
        keyFocused = wantsKeyboard
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: translator.hasDeepLKey ? "DEEPL ПОДКЛЮЧЁН" : "КЛЮЧ DEEPL API")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                closeButton
            }
            Text(verbatim: translator.hasDeepLKey
                 ? "Переводит DeepL. Если он недоступен или кончился лимит — переведёт Apple. Можно вставить другой ключ:"
                 : "Бесплатный тариф DeepL API Free — 500 000 символов в месяц. Скопируй ключ из аккаунта DeepL и вставь сюда (⌘V):")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(text: $keyDraft, prompt: Text(verbatim: "xxxxxxxx-xxxx-…:fx")) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($keyFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
                .onSubmit { saveKey() }
            HStack(spacing: 8) {
                keyButton("Сохранить", prominent: true) { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if translator.hasDeepLKey {
                    keyButton("Отключить DeepL") {
                        translator.removeDeepLKey()
                        mode = .translate
                    }
                }
                Spacer()
                keyButton("Получить ключ") { Translator.openDeepLSignup() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
    }

    private func keyButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(prominent ? Color.black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(prominent ? Color.white : Theme.surfaceHover))
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        translator.saveDeepLKey(key)
        keyDraft = ""
        mode = .translate
        focused = wantsKeyboard
    }

    // MARK: - Scheduling

    private func schedule() async {
        let text = translator.trimmed
        guard !text.isEmpty else {
            configuration = nil
            translator.clear()
            return
        }
        // Wait out the typing: a word is a handful of keystrokes, and a session
        // per letter would be both wasteful and visibly jumpy.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }

        if translator.hasDeepLKey, await translator.runDeepL() { return }
        guard !Task.isCancelled else { return }

        let route = translator.route(for: text)
        if var current = configuration, current.source == route.source, current.target == route.target {
            // Same pair, different text. The modifier only re-runs when the
            // configuration changes, and invalidating is how one says "again".
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: route.source, target: route.target)
        }
    }
}
