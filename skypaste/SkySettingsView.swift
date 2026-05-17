import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: AppSettings
    @ObservedObject var cloudSync: CloudClipboardSyncManager

    init(settings: AppSettings, cloudSync: CloudClipboardSyncManager? = nil) {
        _settings = ObservedObject(wrappedValue: settings)

        let resolvedCloudSync: CloudClipboardSyncManager
        if let cloudSync {
            resolvedCloudSync = cloudSync
        } else {
            let previewStore = ClipboardStore(settings: settings)
            resolvedCloudSync = CloudClipboardSyncManager(store: previewStore, settings: settings)
        }

        _cloudSync = ObservedObject(wrappedValue: resolvedCloudSync)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                generalSettingsSection
                hotKeySection
                behaviorSection
                syncSection
                historySection
                privacySection
            }
            .padding(16)
            .frame(maxWidth: 740, alignment: .leading)
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
        .frame(minWidth: 700, idealWidth: 740, minHeight: 620, idealHeight: 700)
    }

    private var generalSettingsSection: some View {
        SettingsSection(
            title: L10n.tr("settings.general"),
            contentSpacing: 10,
            contentPadding: 12
        ) {
            SettingsRow(title: L10n.tr("settings.appearance")) {
                Picker("", selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { option in
                        Text(L10n.tr(option.titleKey)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }

            Divider()
                .padding(.vertical, 0.5)

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
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("menu.preferences"))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(L10n.tr("app.title"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(versionText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.hotkey"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 136), spacing: 8),
                        GridItem(.flexible(minimum: 136), spacing: 8)
                    ],
                    alignment: .leading,
                    spacing: 8
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

            Divider()
                .padding(.vertical, 1)

            SettingsRow(title: L10n.tr("settings.auto_paste")) {
                Toggle("", isOn: $settings.autoPasteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.auto_paste_hint"))
        }
    }

    private var syncSection: some View {
        SettingsSection(title: L10n.tr("settings.sync")) {
            SettingsRow(title: L10n.tr("settings.universal_clipboard")) {
                Toggle("", isOn: $settings.receiveUniversalClipboardEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.universal_clipboard_hint"))

            Divider()
                .padding(.vertical, 1)

            SettingsRow(title: L10n.tr("settings.icloud_sync")) {
                Toggle("", isOn: $settings.iCloudSyncEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var historySection: some View {
        SettingsSection(title: L10n.tr("settings.history")) {
            SettingsRow(title: L10n.format("settings.max_records", settings.historyLimit)) {
                Stepper("", value: historyLimitBinding, in: 20...1000, step: 20)
                    .labelsHidden()
                    .frame(width: 120, alignment: .trailing)
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: L10n.tr("settings.ignore_apps")) {
            hint(L10n.tr("settings.ignore_apps_hint"))

            TextEditor(text: $settings.ignoredAppsInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 104)
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
        return L10n.format("settings.version_format", version, build)
    }

    private var syncStatusText: String {
        switch cloudSync.status {
        case .disabled:
            return L10n.tr("settings.icloud_sync_status_disabled")
        case .unavailable:
            return L10n.tr("settings.icloud_sync_status_unavailable")
        case .syncing:
            return L10n.tr("settings.icloud_sync_status_syncing")
        case .synced:
            return L10n.tr("settings.icloud_sync_status_synced")
        case .error(let message):
            return L10n.format("settings.icloud_sync_status_error", message)
        }
    }

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { settings.historyLimit },
            set: { settings.setHistoryLimit($0) }
        )
    }

    private var settingsControlFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.54)
    }

    private var infoBadgeFill: Color {
        colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color.white.opacity(0.44)
    }

    private func modifierToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(settingsControlFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func infoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(infoBadgeFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerOnlyRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
        }
    }
}

private struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let contentSpacing: CGFloat
    let contentPadding: CGFloat
    @ViewBuilder let content: Content

    init(
        title: String,
        contentSpacing: CGFloat = 12,
        contentPadding: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.contentSpacing = contentSpacing
        self.contentPadding = contentPadding
        self.content = content()
    }

    private var sectionBackgroundColor: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.62)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            content
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(sectionBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(alignment: .trailing)
        }
    }
}
