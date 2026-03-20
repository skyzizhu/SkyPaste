import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                SettingsCard(title: L10n.tr("settings.language")) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsField(title: L10n.tr("settings.language")) {
                            Picker("", selection: $settings.languageCode) {
                                ForEach(LanguageCatalog.options) { option in
                                    Text(L10n.tr(option.titleKey)).tag(option.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260, alignment: .leading)
                        }

                        HintText(L10n.tr("settings.language_hint"))
                    }
                }

                SettingsCard(title: L10n.tr("settings.hotkey")) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsField(title: L10n.tr("settings.key")) {
                            Picker("", selection: $settings.hotKeyCode) {
                                ForEach(HotKeyCatalog.options) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 180, alignment: .leading)
                        }

                        LazyVGrid(columns: [
                            GridItem(.flexible(minimum: 120), spacing: 12),
                            GridItem(.flexible(minimum: 120), spacing: 12)
                        ], spacing: 10) {
                            modifierToggle(L10n.tr("settings.command"), isOn: $settings.hotKeyCommand)
                            modifierToggle(L10n.tr("settings.shift"), isOn: $settings.hotKeyShift)
                            modifierToggle(L10n.tr("settings.option"), isOn: $settings.hotKeyOption)
                            modifierToggle(L10n.tr("settings.control"), isOn: $settings.hotKeyControl)
                        }

                        valueBadge(L10n.format("settings.current", settings.hotKeyBinding.displayText))
                    }
                }

                SettingsCard(title: L10n.tr("settings.history")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $settings.historyLimit, in: 20...1000, step: 20) {
                            Text(L10n.format("settings.max_records", settings.historyLimit))
                        }

                        HintText(L10n.tr("settings.history_hint"))
                    }
                }

                SettingsCard(title: L10n.tr("settings.startup")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L10n.tr("settings.launch_at_login"), isOn: $settings.launchAtLogin)
                            .toggleStyle(.switch)

                        HintText(L10n.tr("settings.launch_at_login_hint"))
                    }
                }

                SettingsCard(title: L10n.tr("settings.clipboard")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L10n.tr("settings.auto_paste"), isOn: $settings.autoPasteEnabled)
                            .toggleStyle(.switch)

                        HintText(L10n.tr("settings.auto_paste_hint"))
                    }
                }

                SettingsCard(title: L10n.tr("settings.ignore_apps")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HintText(L10n.tr("settings.ignore_apps_hint"))

                        TextEditor(text: $settings.ignoredAppsInput)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                            }

                        valueBadge(L10n.tr("settings.ignore_apps_example"))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, idealWidth: 660, minHeight: 620, idealHeight: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("menu.preferences"))
                .font(.system(size: 24, weight: .semibold))

            Text(L10n.tr("app.title"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private func modifierToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func valueBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 120, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HintText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
