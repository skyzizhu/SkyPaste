import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                generalSection
                hotKeySection
                behaviorSection
                historySection
                privacySection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.06),
                        Color.clear,
                        Color.primary.opacity(0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .frame(minWidth: 720, idealWidth: 760, minHeight: 680, idealHeight: 740)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("menu.preferences"))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(L10n.tr("app.title"))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(versionText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var generalSection: some View {
        SettingsSection(title: L10n.tr("settings.language")) {
            SettingsRow(title: L10n.tr("settings.language")) {
                Picker("", selection: $settings.languageCode) {
                    ForEach(LanguageCatalog.options) { option in
                        Text(L10n.tr(option.titleKey)).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }

            hint(L10n.tr("settings.language_hint"))
        }
    }

    private var hotKeySection: some View {
        SettingsSection(title: L10n.tr("settings.hotkey")) {
            SettingsRow(title: L10n.tr("settings.key")) {
                Picker("", selection: $settings.hotKeyCode) {
                    ForEach(HotKeyCatalog.options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("settings.hotkey"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 140), spacing: 10),
                        GridItem(.flexible(minimum: 140), spacing: 10)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    modifierToggle(L10n.tr("settings.command"), isOn: $settings.hotKeyCommand)
                    modifierToggle(L10n.tr("settings.shift"), isOn: $settings.hotKeyShift)
                    modifierToggle(L10n.tr("settings.option"), isOn: $settings.hotKeyOption)
                    modifierToggle(L10n.tr("settings.control"), isOn: $settings.hotKeyControl)
                }
            }

            infoBadge(L10n.format("settings.current", settings.hotKeyBinding.displayText))
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: L10n.tr("settings.clipboard")) {
            SettingsRow(title: L10n.tr("settings.launch_at_login")) {
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.launch_at_login_hint"))

            Divider()
                .padding(.vertical, 2)

            SettingsRow(title: L10n.tr("settings.auto_paste")) {
                Toggle("", isOn: $settings.autoPasteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.auto_paste_hint"))
        }
    }

    private var historySection: some View {
        SettingsSection(title: L10n.tr("settings.history")) {
            SettingsRow(title: L10n.format("settings.max_records", settings.historyLimit)) {
                Stepper("", value: $settings.historyLimit, in: 20...1000, step: 20)
                    .labelsHidden()
                    .frame(width: 120, alignment: .trailing)
            }

            hint(L10n.tr("settings.history_hint"))
        }
    }

    private var privacySection: some View {
        SettingsSection(title: L10n.tr("settings.ignore_apps")) {
            hint(L10n.tr("settings.ignore_apps_hint"))

            TextEditor(text: $settings.ignoredAppsInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            infoBadge(L10n.tr("settings.ignore_apps_example"))
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private func modifierToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.54))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func infoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.44))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(alignment: .trailing)
        }
    }
}
