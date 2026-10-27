import AppKit
import SwiftUI
import WallpaperCore

struct InspectorScenePropertiesView: View {
    @Localized private var l10n
    @ObservedObject var editor: ScenePropertyEditorModel
    @State private var numbers: [Data: String] = [:]
    @State private var inputFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("场景属性")).font(.headline)
            Text(l10n("设置仅保存在本壁纸的素材库记录中，保存后更新正在使用该场景的窗口。"))
                .font(.caption).foregroundStyle(.secondary)
            if editor.isLoading { ProgressView().controlSize(.small) }
            if let catalog = editor.catalog {
                if catalog.rows.isEmpty { Text(l10n("该场景未声明用户属性。")).foregroundStyle(.secondary) }
                ForEach(catalog.rows, id: \.identity) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.label).font(.callout.weight(.medium))
                            Spacer()
                            if row.readOnlyReason == nil, let value = row.defaultValue {
                                Button(l10n("使用默认值")) {
                                    numbers.removeValue(forKey: row.identity); inputFailure = nil
                                    editor.setValue(value, for: row)
                                }
                                .font(.caption)
                                .accessibilityLabel(l10n("使用默认值") + ": " + row.label)
                            }
                        }
                        if row.readOnlyReason == nil, let value = row.defaultValue {
                            Text(l10n("默认值") + ": " + display(value))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .help(display(value))
                        }
                        if let reason = row.readOnlyReason {
                            Text(l10n.text(readOnlyKey(reason))).font(.caption).foregroundStyle(.secondary)
                        } else if let value = editor.values[row.identity] {
                            control(row, value)
                        } else { Text(l10n("属性值不可用，请重置或重新载入。")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityIdentifier("scene-property-" + row.identity.base64EncodedString())
                }
                .disabled(editor.isSaving || editor.hasInvalidStoredValues)
                HStack {
                    Button(l10n("保存并应用")) { save() }
                        .disabled(editor.hasInvalidStoredValues || !validNumbers || inputFailure != nil)
                        .accessibilityIdentifier("scene-properties-save")
                    Button(l10n("重置属性")) {
                        let revision = editor.selectionRevision
                        Task {
                            _ = await editor.reset(expectedRevision: revision)
                            if editor.status != nil { numbers = [:]; inputFailure = nil }
                        }
                    }.accessibilityIdentifier("scene-properties-reset")
                }.disabled(editor.isLoading || editor.isSaving)
            }
            Button(l10n("重新载入属性")) { numbers = [:]; inputFailure = nil; editor.reload() }
                .disabled(editor.isLoading || editor.isSaving)
            if !validNumbers { Text(l10n("请输入有效的有限数字。")).font(.caption).foregroundStyle(.red) }
            if let inputFailure { Text(l10n.text(inputFailure)).font(.caption).foregroundStyle(.red) }
            if let failure = editor.failure {
                FailureNotice(failure: PresentedFailure(title: "场景属性操作失败",
                    summary: "请检查属性值或重新载入场景。", diagnostics: failure.localizedDescription))
            }
            if let status = editor.status { Text(l10n.text(status)).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("scene-properties")
        .onChange(of: editor.selectionRevision) { _, _ in numbers = [:]; inputFailure = nil }
    }

    @ViewBuilder private func control(_ row: ScenePropertyDefinition, _ value: ScenePropertyValue) -> some View {
        switch (row.kind, value) {
        case (.bool, .boolean(let value)):
            Toggle(row.label, isOn: Binding(get: { value }, set: { editor.setValue(.boolean($0), for: row) }))
                .labelsHidden().toggleStyle(.switch)
        case (.slider, .number(let value)):
            TextField(row.label, text: Binding(get: { numbers[row.identity] ?? String(value) },
                set: { numbers[row.identity] = $0; inputFailure = nil; editor.beginEditing() }))
                .textFieldStyle(.roundedBorder).accessibilityLabel(row.label)
            if let minimum = row.minimum, let maximum = row.maximum,
               minimum < maximum, (maximum - minimum).isFinite, (minimum...maximum).contains(value) {
                let binding = Binding(get: { value }, set: { value in
                    numbers[row.identity] = String(value); editor.setValue(.number(value), for: row)
                })
                if let step = row.step { Slider(value: binding, in: minimum...maximum, step: step).accessibilityLabel(row.label) }
                else { Slider(value: binding, in: minimum...maximum).accessibilityLabel(row.label) }
            }
        case (.color, .string(let value)):
            if let color = color(value) {
                ColorPicker(row.label, selection: Binding(get: { color }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                        inputFailure = "无法读取所选颜色的 RGB 分量。"; return
                    }
                    editor.setValue(.string("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)"), for: row)
                    inputFailure = nil
                }), supportsOpacity: false).labelsHidden()
            }
            TextField(row.label, text: Binding(get: { value }, set: { editor.setValue(.string($0), for: row); inputFailure = nil }))
                .textFieldStyle(.roundedBorder).accessibilityLabel(row.label)
        case (.textinput, .string(let value)):
            TextField(row.label, text: Binding(get: { value }, set: { editor.setValue(.string($0), for: row) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel(row.label)
        case (.combo, .string(let value)):
            Picker(row.label, selection: Binding(get: { Data(value.utf8) }, set: { identity in
                if let choice = row.options.first(where: { $0.identity == identity }) {
                    editor.setValue(.string(choice.value), for: row)
                }
            })) {
                ForEach(Array(row.options.enumerated()), id: \.offset) { _, choice in
                    Text(choice.label).tag(choice.identity)
                }
            }.labelsHidden()
        default: Text(l10n("属性值不可用，请重置或重新载入。")).foregroundStyle(.secondary)
        }
    }

    private func display(_ value: ScenePropertyValue) -> String {
        switch value {
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .string(let value): value
        }
    }

    private var validNumbers: Bool {
        numbers.values.allSatisfy { Double($0).map(\.isFinite) == true }
    }

    private func save() {
        guard validNumbers, let catalog = editor.catalog else { return }
        for row in catalog.rows where row.kind == .slider {
            if let text = numbers[row.identity], let value = Double(text) {
                editor.setValue(.number(value), for: row)
            }
        }
        let revision = editor.selectionRevision
        Task { _ = await editor.save(expectedRevision: revision) }
    }

    private func color(_ value: String) -> Color? {
        let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        let parts = value.components(separatedBy: whitespace).filter { !$0.isEmpty }
        guard parts.count == 3, let red = Double(parts[0]), let green = Double(parts[1]), let blue = Double(parts[2]),
              [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    private func readOnlyKey(_ reason: ScenePropertyReadOnlyReason) -> String {
        switch reason {
        case .presetOnly: "仅有预设值，缺少属性声明。"
        case .unsupportedName: "此属性名称不受运行时支持。"
        case .invalidDeclaration: "属性声明无效。"
        case .unsupportedType: "此属性类型尚不受支持。"
        case .unsupportedCondition: "此属性依赖暂不支持的显示条件。"
        }
    }
}
