import AppKit
import WallpaperCore

/// Native transient inputs. Draft text stays local until Return or Apply succeeds.
@MainActor final class EditorPreviewPropertiesView: NSStackView {
    private let t: (String) -> String
    private let rows = NSStackView()
    private let reset = NSButton()
    private let commandError = NSTextField(wrappingLabelWithString: "")
    private var inputs: [EditorPreviewPropertyInput] = []
    private var epoch: String?
    var onSubmit: (([String: Any]) async throws -> Void)?
    var onReset: (() async throws -> Void)?

    init(localize: @escaping (String) -> String) {
        t = localize; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        let title = NSTextField(labelWithString: t("previewProperties")); title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let note = NSTextField(wrappingLabelWithString: t("previewPropertiesNote"))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
        rows.orientation = .vertical; rows.alignment = .width; rows.spacing = 8
        reset.title = t("previewPropertiesReset"); reset.bezelStyle = .rounded
        reset.target = self; reset.action = #selector(resetValues)
        reset.identifier = NSUserInterfaceItemIdentifier("editor-property-reset")
        reset.setAccessibilityIdentifier("editor-property-reset")
        commandError.textColor = .systemOrange; commandError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for view in [title, note, rows, reset, commandError] { addArrangedSubview(view) }
        for view in [note, rows, commandError] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ properties: EditorPreviewProperties?, inspectionFailure: Error? = nil) {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        inputs = []; epoch = nil
        if let inspectionFailure {
            let error = NSTextField(wrappingLabelWithString: t("previewPropertiesInspectionFailed") + " " + inspectionFailure.localizedDescription)
            error.identifier = NSUserInterfaceItemIdentifier("editor-property-inspection-error")
            error.textColor = .systemOrange; error.font = .systemFont(ofSize: NSFont.smallSystemFontSize); error.isSelectable = true
            rows.addArrangedSubview(error); error.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            return
        }
        guard let properties, !properties.rows.isEmpty else {
            rows.addArrangedSubview(NSTextField(wrappingLabelWithString: t("previewPropertiesEmpty"))); return
        }
        for row in properties.rows {
            let input = EditorPreviewPropertyInput(row: row, localize: t)
            input.onSubmit = { [weak self] values in
                guard let self, let onSubmit = self.onSubmit else { throw WallpaperError("Preview property command is not connected") }
                try await onSubmit(values)
            }
            inputs.append(input); rows.addArrangedSubview(input)
        }
    }
    func update(values: EditorPreviewPropertyValues, enabled: Bool, origin: String?, failure: Error?) {
        let changedOrigin = epoch != origin; epoch = origin
        for input in inputs { input.update(value: values[input.name], enabled: enabled, force: changedOrigin) }
        reset.isEnabled = enabled && inputs.contains { $0.editable }
        commandError.stringValue = failure.map { t("previewPropertiesCommandError") + " " + $0.localizedDescription } ?? ""
    }
    @objc private func resetValues() {
        Task { @MainActor in
            do {
                guard let onReset else { throw WallpaperError("Preview property reset is not connected") }
                try await onReset()
                for input in inputs { input.restoreAcknowledgedDraft() }
            }
            catch { commandError.stringValue = t("previewPropertiesCommandError") + " " + error.localizedDescription }
        }
    }
}

@MainActor private final class EditorPreviewPropertyInput: NSStackView {
    private let row: EditorPreviewProperties.Row
    private let t: (String) -> String
    private let field = NSTextField()
    private let toggle = NSButton()
    private let options = NSPopUpButton()
    private let apply = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var slider: NSSlider?
    private var acknowledged: EditorPreviewPropertyValue?
    private var controlsEnabled = false
    var onSubmit: (([String: Any]) async throws -> Void)?
    var name: String { row.name }
    var editable: Bool { row.readOnlyReason == nil }

    init(row: EditorPreviewProperties.Row, localize: @escaping (String) -> String) {
        self.row = row; t = localize; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 3
        let label = NSTextField(wrappingLabelWithString: row.text.map { "\($0) [\(row.name)]" } ?? row.name)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize); addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        if let reason = row.readOnlyReason {
            let readOnly = NSTextField(wrappingLabelWithString: t("previewPropertiesReadOnly") + " " + t("previewPropertyReason_" + reason))
            readOnly.textColor = .secondaryLabelColor; readOnly.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            addArrangedSubview(readOnly); readOnly.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            let raw = NSTextField(labelWithString: row.rawDescription)
            raw.lineBreakMode = .byTruncatingTail; raw.toolTip = row.rawDescription; raw.isSelectable = true
            raw.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            addArrangedSubview(raw); raw.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            return
        }
        switch row.type {
        case "bool":
            toggle.setButtonType(.switch); toggle.title = t("previewPropertyBool")
            toggle.target = self; toggle.action = #selector(submit)
            toggle.identifier = NSUserInterfaceItemIdentifier("editor-property-input-" + row.name)
            addArrangedSubview(toggle)
        case "combo":
            // NSPopUpButton.addItem(withTitle:) collapses identical labels.
            // NSMenu preserves their positions and distinct declared values.
            let menu = NSMenu()
            for option in row.options ?? [] { menu.addItem(withTitle: option.label, action: nil, keyEquivalent: "") }
            options.menu = menu
            options.target = self; options.action = #selector(submit)
            options.identifier = NSUserInterfaceItemIdentifier("editor-property-input-" + row.name)
            addArrangedSubview(options); options.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        default:
            field.identifier = NSUserInterfaceItemIdentifier("editor-property-input-" + row.name)
            field.setAccessibilityIdentifier("editor-property-input-" + row.name)
            field.target = self; field.action = #selector(submit)
            field.setAccessibilityLabel(label.stringValue)
            addArrangedSubview(field); field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            if row.type == "slider", let min = row.min, let max = row.max, min < max {
                let slider = NSSlider(value: 0, minValue: min, maxValue: max, target: self, action: #selector(slide))
                self.slider = slider; addArrangedSubview(slider); slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
            if row.type == "slider" || row.type == "color" {
                var hint = row.type == "color" ? t("previewPropertyRGB") : t("previewPropertyNumber")
                if let min = row.min { hint += " · min \(min)" }; if let max = row.max { hint += " · max \(max)" }
                if let step = row.step { hint += " · step \(step)" }
                let description = NSTextField(wrappingLabelWithString: hint)
                description.font = .systemFont(ofSize: NSFont.smallSystemFontSize); description.textColor = .secondaryLabelColor
                addArrangedSubview(description); description.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
            apply.title = t("previewPropertiesApply"); apply.bezelStyle = .rounded; apply.target = self; apply.action = #selector(submit)
            apply.identifier = NSUserInterfaceItemIdentifier("editor-property-apply-" + row.name)
            addArrangedSubview(apply)
        }
        errorLabel.identifier = NSUserInterfaceItemIdentifier("editor-property-error-" + row.name)
        errorLabel.textColor = .systemOrange; errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addArrangedSubview(errorLabel); errorLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        update(value: row.value, enabled: false, force: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(value: EditorPreviewPropertyValue?, enabled: Bool, force: Bool) {
        guard editable else { return }
        controlsEnabled = enabled
        field.isEnabled = enabled; toggle.isEnabled = enabled; options.isEnabled = enabled; apply.isEnabled = enabled; slider?.isEnabled = enabled
        guard force || acknowledged != value else { return }; acknowledged = value
        field.stringValue = value?.display ?? ""
        if case .bool(let value) = value { toggle.state = value ? .on : .off }
        if case .number(let value) = value { slider?.doubleValue = value }
        if let index = row.options?.firstIndex(where: { $0.value == value }) { options.selectItem(at: index) }
        errorLabel.stringValue = ""
    }
    func restoreAcknowledgedDraft() { update(value: acknowledged, enabled: controlsEnabled, force: true) }
    @objc private func slide() { if let slider { field.stringValue = String(slider.doubleValue) } }
    private func draft() throws -> EditorPreviewPropertyValue {
        switch row.type {
        case "bool": return .bool(toggle.state == .on)
        case "combo":
            guard let declared = row.options, declared.indices.contains(options.indexOfSelectedItem) else { throw NSError(domain: "Invalid selection", code: 1) }
            return declared[options.indexOfSelectedItem].value
        case "slider":
            let source = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(source), number.isFinite else { throw NSError(domain: t("previewPropertyInvalidNumber"), code: 1) }
            return .number(number)
        default: return .string(field.stringValue)
        }
    }
    @objc private func submit() {
        do {
            let value = try draft(); try row.validate(value); errorLabel.stringValue = ""
            Task { @MainActor in
                do {
                    guard let onSubmit else { throw WallpaperError("Preview property command is not connected") }
                    try await onSubmit([row.name: value.rawValue])
                }
                catch { errorLabel.stringValue = t("previewPropertiesCommandError") + " " + error.localizedDescription }
            }
        } catch { errorLabel.stringValue = t("previewPropertiesInvalid") + " " + error.localizedDescription }
    }
}
