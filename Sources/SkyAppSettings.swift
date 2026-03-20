import Carbon
import Foundation
import ServiceManagement

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let titleKey: String
}

struct LanguageCatalog {
    static let system = "system"
    static let defaultsKey = "settings.languageCode"
    static let options: [LanguageOption] = [
        .init(id: system, titleKey: "language.system"),
        .init(id: "en", titleKey: "language.en"),
        .init(id: "zh-Hans", titleKey: "language.zh-Hans"),
        .init(id: "zh-Hant", titleKey: "language.zh-Hant"),
        .init(id: "ja", titleKey: "language.ja"),
        .init(id: "ko", titleKey: "language.ko"),
        .init(id: "fr", titleKey: "language.fr")
    ]

    static func isSupported(_ languageCode: String) -> Bool {
        options.contains(where: { $0.id == languageCode })
    }
}

struct HotKeyOption: Identifiable, Hashable {
    let id: UInt32
    let title: String
}

struct HotKeyCatalog {
    static let options: [HotKeyOption] = [
        .init(id: UInt32(kVK_ANSI_A), title: "A"),
        .init(id: UInt32(kVK_ANSI_B), title: "B"),
        .init(id: UInt32(kVK_ANSI_C), title: "C"),
        .init(id: UInt32(kVK_ANSI_D), title: "D"),
        .init(id: UInt32(kVK_ANSI_E), title: "E"),
        .init(id: UInt32(kVK_ANSI_F), title: "F"),
        .init(id: UInt32(kVK_ANSI_G), title: "G"),
        .init(id: UInt32(kVK_ANSI_H), title: "H"),
        .init(id: UInt32(kVK_ANSI_I), title: "I"),
        .init(id: UInt32(kVK_ANSI_J), title: "J"),
        .init(id: UInt32(kVK_ANSI_K), title: "K"),
        .init(id: UInt32(kVK_ANSI_L), title: "L"),
        .init(id: UInt32(kVK_ANSI_M), title: "M"),
        .init(id: UInt32(kVK_ANSI_N), title: "N"),
        .init(id: UInt32(kVK_ANSI_O), title: "O"),
        .init(id: UInt32(kVK_ANSI_P), title: "P"),
        .init(id: UInt32(kVK_ANSI_Q), title: "Q"),
        .init(id: UInt32(kVK_ANSI_R), title: "R"),
        .init(id: UInt32(kVK_ANSI_S), title: "S"),
        .init(id: UInt32(kVK_ANSI_T), title: "T"),
        .init(id: UInt32(kVK_ANSI_U), title: "U"),
        .init(id: UInt32(kVK_ANSI_V), title: "V"),
        .init(id: UInt32(kVK_ANSI_W), title: "W"),
        .init(id: UInt32(kVK_ANSI_X), title: "X"),
        .init(id: UInt32(kVK_ANSI_Y), title: "Y"),
        .init(id: UInt32(kVK_ANSI_Z), title: "Z")
    ]

    static func title(for keyCode: UInt32) -> String {
        options.first(where: { $0.id == keyCode })?.title ?? L10n.format("hotkey.keycode", keyCode)
    }
}

struct HotKeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayText: String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append(L10n.tr("hotkey.cmd")) }
        if modifiers & UInt32(shiftKey) != 0 { parts.append(L10n.tr("hotkey.shift")) }
        if modifiers & UInt32(optionKey) != 0 { parts.append(L10n.tr("hotkey.option")) }
        if modifiers & UInt32(controlKey) != 0 { parts.append(L10n.tr("hotkey.control")) }
        parts.append(HotKeyCatalog.title(for: keyCode))
        return parts.joined(separator: "+")
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var historyLimit: Int {
        didSet {
            historyLimit = Self.clampHistoryLimit(historyLimit)
            defaults.set(historyLimit, forKey: Keys.historyLimit)
        }
    }

    @Published var hotKeyCode: UInt32 {
        didSet {
            defaults.set(Int(hotKeyCode), forKey: Keys.hotKeyCode)
            if oldValue != hotKeyCode {
                NotificationCenter.default.post(name: .hotKeySettingsChanged, object: nil)
            }
        }
    }

    @Published var hotKeyCommand: Bool {
        didSet {
            defaults.set(hotKeyCommand, forKey: Keys.hotKeyCommand)
            if oldValue != hotKeyCommand {
                NotificationCenter.default.post(name: .hotKeySettingsChanged, object: nil)
            }
        }
    }

    @Published var hotKeyShift: Bool {
        didSet {
            defaults.set(hotKeyShift, forKey: Keys.hotKeyShift)
            if oldValue != hotKeyShift {
                NotificationCenter.default.post(name: .hotKeySettingsChanged, object: nil)
            }
        }
    }

    @Published var hotKeyOption: Bool {
        didSet {
            defaults.set(hotKeyOption, forKey: Keys.hotKeyOption)
            if oldValue != hotKeyOption {
                NotificationCenter.default.post(name: .hotKeySettingsChanged, object: nil)
            }
        }
    }

    @Published var hotKeyControl: Bool {
        didSet {
            defaults.set(hotKeyControl, forKey: Keys.hotKeyControl)
            if oldValue != hotKeyControl {
                NotificationCenter.default.post(name: .hotKeySettingsChanged, object: nil)
            }
        }
    }

    @Published var ignoredAppsInput: String {
        didSet {
            defaults.set(ignoredAppsInput, forKey: Keys.ignoredAppsInput)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLoginSetting()
        }
    }

    @Published var languageCode: String {
        didSet {
            if !LanguageCatalog.isSupported(languageCode) {
                languageCode = LanguageCatalog.system
            }
            defaults.set(languageCode, forKey: Keys.languageCode)
            if oldValue != languageCode {
                NotificationCenter.default.post(name: .languageSettingsChanged, object: nil)
            }
        }
    }

    var hotKeyBinding: HotKeyBinding {
        var modifiers: UInt32 = 0
        if hotKeyCommand { modifiers |= UInt32(cmdKey) }
        if hotKeyShift { modifiers |= UInt32(shiftKey) }
        if hotKeyOption { modifiers |= UInt32(optionKey) }
        if hotKeyControl { modifiers |= UInt32(controlKey) }

        return HotKeyBinding(keyCode: hotKeyCode, modifiers: modifiers)
    }

    var ignoredBundleIDs: Set<String> {
        let separators = CharacterSet(charactersIn: ",\n")
        return Set(
            ignoredAppsInput
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let historyLimit = "settings.historyLimit"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyCommand = "settings.hotKeyCommand"
        static let hotKeyShift = "settings.hotKeyShift"
        static let hotKeyOption = "settings.hotKeyOption"
        static let hotKeyControl = "settings.hotKeyControl"
        static let ignoredAppsInput = "settings.ignoredAppsInput"
        static let launchAtLogin = "settings.launchAtLogin"
        static let languageCode = LanguageCatalog.defaultsKey
    }

    private init() {
        let savedHistory = defaults.integer(forKey: Keys.historyLimit)
        self.historyLimit = Self.clampHistoryLimit(savedHistory == 0 ? 200 : savedHistory)

        let savedCode = defaults.integer(forKey: Keys.hotKeyCode)
        self.hotKeyCode = UInt32(savedCode == 0 ? Int(kVK_ANSI_V) : savedCode)

        self.hotKeyCommand = defaults.object(forKey: Keys.hotKeyCommand) as? Bool ?? true
        self.hotKeyShift = defaults.object(forKey: Keys.hotKeyShift) as? Bool ?? true
        self.hotKeyOption = defaults.object(forKey: Keys.hotKeyOption) as? Bool ?? false
        self.hotKeyControl = defaults.object(forKey: Keys.hotKeyControl) as? Bool ?? false
        self.ignoredAppsInput = defaults.string(forKey: Keys.ignoredAppsInput) ?? ""
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        let savedLanguage = defaults.string(forKey: Keys.languageCode) ?? LanguageCatalog.system
        self.languageCode = LanguageCatalog.isSupported(savedLanguage) ? savedLanguage : LanguageCatalog.system

        applyLaunchAtLoginSetting()
    }

    private func applyLaunchAtLoginSetting() {
        guard #available(macOS 13.0, *) else { return }

        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[AppSettings] Launch at login update failed: \(error)")
        }
    }

    private static func clampHistoryLimit(_ value: Int) -> Int {
        min(max(value, 20), 1000)
    }
}

extension Notification.Name {
    static let hotKeySettingsChanged = Notification.Name("hotKeySettingsChanged")
    static let languageSettingsChanged = Notification.Name("languageSettingsChanged")
}
