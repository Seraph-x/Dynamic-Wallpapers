import SwiftUI
import WallpaperCore

struct AppearanceSettingsView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @State private var accentCode: String
    @State private var accentCodeIsInvalid = false
    @State private var isEditingAccentCode = false

    init(model: AppModel) {
        self.model = model
        _accentCode = State(initialValue: model.library.settings.appearance.accentColor.hexCode)
    }

    var body: some View {
        Form {
            Section(l10n("主题")) {
                Picker(l10n("外观模式"), selection: binding(\.theme)) {
                    Text(l10n("跟随系统")).tag(AppTheme.system)
                    Text(l10n("浅色")).tag(AppTheme.light)
                    Text(l10n("深色")).tag(AppTheme.dark)
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("interface-theme")
                HStack {
                    ColorPicker(l10n("主题颜色"), selection: accentColorBinding, supportsOpacity: false)
                    VStack(spacing: 4) {
                        Text(l10n("颜色代码")).frame(maxWidth: .infinity)
                        CenteredColorCodeField(text: $accentCode, isEditing: $isEditingAccentCode,
                                               label: l10n("颜色代码"), onSubmit: restoreCanonicalAccentCode)
                    }.frame(width: 108)
                }
                if accentCodeIsInvalid {
                    Text(l10n("请输入 #RRGGBB 格式的颜色代码。"))
                        .font(.caption).foregroundStyle(.red)
                }
            }.disabled(model.loadFailed || model.isShuttingDown)
            Section(l10n("界面背景")) {
                HStack {
                    Slider(value: binding(\.transparency), in: 0...1) {
                        Text(l10n("背景透明度"))
                    }
                    Text(model.library.settings.appearance.transparency, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Picker(l10n("模糊效果"), selection: binding(\.blur)) {
                    Text(l10n("清透")).tag(GlassBlurStyle.clear)
                    Text(l10n("磨砂")).tag(GlassBlurStyle.frosted)
                }.pickerStyle(.segmented)
                Picker(l10n("全屏背景帧率"), selection: binding(\.fullScreenFrameRate)) {
                    ForEach(WallpaperMirrorFrameRate.allCases, id: \.self) { rate in
                        Text("\(rate.rawValue) Hz").tag(rate)
                    }
                }.pickerStyle(.segmented)
                Picker(l10n("网页壁纸帧率"), selection: Binding(
                    get: { model.library.settings.webWallpaperFrameRate },
                    set: { value in model.mutate { $0.settings.webWallpaperFrameRate = value } })) {
                    ForEach(WebWallpaperFrameRate.allCases, id: \.self) { rate in
                        Text("\(rate.rawValue) FPS").tag(rate)
                    }
                }.pickerStyle(.segmented)
            }
            .disabled(model.loadFailed || model.isShuttingDown)
            if let failure = model.appearanceFailure ?? (model.loadFailed ? model.failure : nil) {
                Section { FailureNotice(failure: failure) }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .onChange(of: accentCode) { _, value in applyAccentCode(value) }
            .onChange(of: isEditingAccentCode) { _, editing in
                if !editing { restoreCanonicalAccentCode() }
            }
            .onChange(of: model.library.settings.appearance.accentColor) { _, color in
                guard !isEditingAccentCode else { return }
                accentCode = color.hexCode; accentCodeIsInvalid = false
            }
    }

    private var accentColorBinding: Binding<Color> {
        Binding(get: {
            Color(nsColor: AppColors.sRGB(model.library.settings.appearance.accentColor))
        }, set: { color in
            guard let accent = AppColors.accentColor(from: color) else {
                accentCodeIsInvalid = true; return
            }
            var appearance = model.library.settings.appearance
            appearance.accentColor = accent
            if model.setAppearance(appearance) {
                accentCode = accent.hexCode; accentCodeIsInvalid = false
            }
        })
    }

    private func applyAccentCode(_ code: String) {
        guard let accent = try? AppAccentColor(hexCode: code) else {
            accentCodeIsInvalid = true; return
        }
        accentCodeIsInvalid = false
        guard accent != model.library.settings.appearance.accentColor else { return }
        var appearance = model.library.settings.appearance
        appearance.accentColor = accent
        _ = model.setAppearance(appearance)
    }

    private func restoreCanonicalAccentCode() {
        guard !accentCodeIsInvalid else { return }
        accentCode = model.library.settings.appearance.accentColor.hexCode
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppAppearanceSettings, Value>) -> Binding<Value> {
        Binding(get: { model.library.settings.appearance[keyPath: keyPath] }, set: { value in
            var appearance = model.library.settings.appearance
            appearance[keyPath: keyPath] = value
            model.setAppearance(appearance)
        })
    }
}

private struct CenteredColorCodeField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let label: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("accent-color-code")
        field.cell?.setAccessibilityLabel(label)
        field.cell?.setAccessibilityIdentifier("accent-color-code")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEditing = $isEditing
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        field.alignment = .center
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(label)
        field.cell?.setAccessibilityLabel(label)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isEditing: Binding<Bool>
        var onSubmit: () -> Void

        init(text: Binding<String>, isEditing: Binding<Bool>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.onSubmit = onSubmit
        }

        func controlTextDidBeginEditing(_ notification: Notification) { isEditing.wrappedValue = true }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let entered = field.stringValue
            guard !entered.isEmpty, !entered.hasPrefix("#") else {
                text.wrappedValue = entered
                return
            }
            let editor = field.currentEditor() as? NSTextView
            let selection = editor?.selectedRange()
            let normalized = "#" + entered
            field.stringValue = normalized
            if let editor {
                editor.string = normalized
                if let selection, selection.location != NSNotFound {
                    editor.setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
                }
            }
            text.wrappedValue = normalized
        }

        func controlTextDidEndEditing(_ notification: Notification) { isEditing.wrappedValue = false }

        @objc func submit() { onSubmit() }
    }
}
