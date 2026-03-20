import Foundation

enum L10n {
    private static var currentLanguageCode: String {
        let stored = UserDefaults.standard.string(forKey: LanguageCatalog.defaultsKey) ?? LanguageCatalog.system
        if stored != LanguageCatalog.system, LanguageCatalog.isSupported(stored) {
            return stored
        }
        return resolvedSystemLanguageCode()
    }

    private static var bundle: Bundle {
        let languageCode = currentLanguageCode
        guard languageCode != LanguageCatalog.system else { return .module }

        if let path = Bundle.module.path(forResource: resourceFolderName(for: languageCode), ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        return .module
    }

    private static var locale: Locale {
        let languageCode = currentLanguageCode
        return languageCode == LanguageCatalog.system ? .current : Locale(identifier: languageCode)
    }

    static func tr(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle, locale: locale)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func sectionTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return tr("section.today") }
        if calendar.isDateInYesterday(day) { return tr("section.yesterday") }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMdd")
        return formatter.string(from: day)
    }

    static func timeText(_ date: Date) -> String {
        var formatStyle = Date.FormatStyle(date: .omitted, time: .standard)
        formatStyle.locale = locale
        return date.formatted(formatStyle)
    }

    private static func resolvedSystemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages
        for candidate in preferred {
            if let matched = normalizedSupportedLanguage(from: candidate) {
                return matched
            }
        }

        if let matched = normalizedSupportedLanguage(from: Locale.current.identifier) {
            return matched
        }

        return LanguageCatalog.system
    }

    private static func normalizedSupportedLanguage(from identifier: String) -> String? {
        if LanguageCatalog.isSupported(identifier) {
            return identifier
        }

        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh-hans") { return "zh-Hans" }
        if lowercased.hasPrefix("zh-hant") { return "zh-Hant" }
        if lowercased.hasPrefix("en") { return "en" }
        if lowercased.hasPrefix("ja") { return "ja" }
        if lowercased.hasPrefix("ko") { return "ko" }
        if lowercased.hasPrefix("fr") { return "fr" }
        return nil
    }

    private static func resourceFolderName(for languageCode: String) -> String {
        switch languageCode {
        case "zh-Hans":
            return "zh-hans"
        case "zh-Hant":
            return "zh-hant"
        default:
            return languageCode
        }
    }
}
