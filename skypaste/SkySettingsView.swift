import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: AppSettings
    @ObservedObject var cloudSync: CloudClipboardSyncManager
    @ObservedObject var store: ClipboardStore

    init(settings: AppSettings, store: ClipboardStore? = nil, cloudSync: CloudClipboardSyncManager? = nil) {
        _settings = ObservedObject(wrappedValue: settings)

        let resolvedStore: ClipboardStore
        if let store {
            resolvedStore = store
        } else {
            resolvedStore = ClipboardStore(settings: settings)
        }

        let resolvedCloudSync: CloudClipboardSyncManager
        if let cloudSync {
            resolvedCloudSync = cloudSync
        } else {
            resolvedCloudSync = CloudClipboardSyncManager(store: resolvedStore, settings: settings)
        }

        _store = ObservedObject(wrappedValue: resolvedStore)
        _cloudSync = ObservedObject(wrappedValue: resolvedCloudSync)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                generalSettingsSection
                hotKeySection
                syncSection
                librarySection
                supportSection
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

            Divider()
                .padding(.vertical, 0.5)

            SettingsRow(title: L10n.tr("settings.launch_at_login")) {
                Toggle("", isOn: animatedToggleBinding($settings.launchAtLogin))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()
                .padding(.vertical, 0.5)

            SettingsRow(title: L10n.tr("settings.auto_paste")) {
                Toggle("", isOn: animatedToggleBinding($settings.autoPasteEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.auto_paste_hint"))
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: Self.settingsAppIcon)
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

    private var syncSection: some View {
        SettingsSection(title: L10n.tr("settings.sync")) {
            SettingsRow(title: L10n.tr("settings.universal_clipboard")) {
                Toggle("", isOn: animatedToggleBinding($settings.receiveUniversalClipboardEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.universal_clipboard_hint"))

            Divider()
                .padding(.vertical, 1)

            SettingsRow(title: L10n.tr("settings.icloud_sync")) {
                Toggle("", isOn: animatedToggleBinding($settings.iCloudSyncEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if settings.iCloudSyncEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .padding(.vertical, 1)

                    SettingsRow(title: L10n.tr("settings.icloud_sync_upload")) {
                        Toggle("", isOn: animatedToggleBinding($settings.iCloudSyncUploadEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()
                        .padding(.vertical, 1)

                    SettingsRow(title: L10n.tr("settings.icloud_sync_receive")) {
                        Toggle("", isOn: animatedToggleBinding($settings.iCloudSyncReceiveEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    hint(L10n.tr("settings.icloud_sync_rules_hint"))
                }
                .padding(.leading, 18)
            }

            Divider()
                .padding(.vertical, 1)

            SettingsRow(title: L10n.tr("settings.privacy_filter")) {
                Toggle("", isOn: animatedToggleBinding($settings.privacyContentFilteringEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            hint(L10n.tr("settings.privacy_filter_hint"))
        }
    }

    private var librarySection: some View {
        SettingsSection(title: L10n.tr("settings.library"), contentSpacing: 10) {
            SettingsRow(title: L10n.format("settings.max_records", settings.historyLimit)) {
                Stepper("", value: historyLimitBinding, in: 20...1000, step: 20)
                    .labelsHidden()
                    .frame(width: 120, alignment: .trailing)
            }

            Divider()
                .padding(.vertical, 0.5)

            Text(L10n.tr("settings.ignore_apps"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            TextEditor(text: $settings.ignoredAppsInput)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 82, maxHeight: 82, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(settingsControlFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }

            hint("\(L10n.tr("settings.ignore_apps_hint")) \(L10n.tr("settings.ignore_apps_example"))")

            if !ignoredAppSuggestions.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    Text(L10n.tr("settings.ignore_apps_suggestions"))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ignoredAppSuggestions, id: \.self) { appName in
                                Button {
                                    appendIgnoredApp(appName)
                                } label: {
                                    Text(appName)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(settingsControlFill)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                .padding(.top, -2)
                .padding(.bottom, -3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var supportSection: some View {
        SettingsSection(title: L10n.tr("settings.support"), contentSpacing: 10) {
            promotionalCard(
                icon: AnyView(appIcon),
                title: L10n.tr("app.title"),
                subtitle: L10n.tr("settings.rate_app_subtitle"),
                actionTitle: L10n.tr("settings.rate_app_action"),
                action: openAppReview
            )

            Divider()
                .padding(.vertical, 0.5)

            promotionalCard(
                icon: AnyView(yourToolsLogo),
                title: L10n.tr("yourtools.title"),
                subtitle: L10n.tr("yourtools.subtitle"),
                actionTitle: L10n.tr("yourtools.open"),
                action: openYourTools
            )
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L10n.format("settings.version_format", version, build)
    }

    private var ignoredAppSuggestions: [String] {
        let existing = settings.ignoredApps
        let suggestions = store.items
            .compactMap(\.sourceApp?.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { partial, name in
                if !partial.contains(name) {
                    partial.append(name)
                }
            }

        return Array(
            suggestions
                .filter { !existing.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
                .prefix(8)
        )
    }

    private var yourToolsLogo: some View {
        promoIconContainer {
            if let image = Self.cachedYourToolsLogo {
                promoIconImage(image, scale: 0.84)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
            }
        }
    }

    private var appIcon: some View {
        promoIconContainer {
            promoIconImage(Self.settingsAppIcon)
        }
    }

    private static let cachedYourToolsLogo: NSImage? = {
        guard let imageURL = Bundle.main.url(forResource: "yourtools-logo", withExtension: "jpg") else {
            return nil
        }
        return NSImage(contentsOf: imageURL)
    }()

    private static let settingsAppIcon: NSImage = {
        NSImage(named: NSImage.Name("AppIcon")) ?? NSApp.applicationIconImage
    }()

    private func appendIgnoredApp(_ appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !settings.ignoredApps.contains(normalized) else { return }

        let current = settings.ignoredAppsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            settings.ignoredAppsInput = trimmed
        } else {
            settings.ignoredAppsInput = current + "\n" + trimmed
        }
    }

    private func openYourTools() {
        guard let url = URL(string: "https://apps.apple.com/us/app/your-tools-ai-toolbox/id6670400942") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAppReview() {
        guard let url = URL(string: "https://apps.apple.com/app/id6760884520?action=write-review") else { return }
        NSWorkspace.shared.open(url)
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
        Toggle(isOn: animatedToggleBinding(isOn)) {
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

    private func promoIconContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
        }
        .frame(width: 64, height: 64)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 8, y: 4)
    }

    private func promoIconImage(_ image: NSImage, scale: CGFloat = 1) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(scale)
    }

    private func animatedToggleBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.16)) {
                    binding.wrappedValue = newValue
                }
            }
        )
    }

    private func promotionalCard(
        icon: AnyView,
        title: String,
        subtitle: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    )
            }
            .buttonStyle(.plain)
            .help(actionTitle)
        }
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
