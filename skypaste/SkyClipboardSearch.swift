import Foundation

struct ClipboardSourceAppOption: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

enum ClipboardSourceSelection: Hashable {
    case allApps
    case phone
    case app(bundleID: String)

    var cacheKey: String {
        switch self {
        case .allApps:
            return "all-apps"
        case .phone:
            return "phone"
        case .app(let bundleID):
            return "app:\(bundleID)"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .allApps:
            return true
        case .phone:
            return item.source.isDeviceSynced
        case .app(let bundleID):
            return item.sourceApp?.bundleID == bundleID
        }
    }
}

struct ClipboardSearchQuery {
    enum ItemType: Hashable {
        case text
        case image
        case file
        case folder
        case code
        case url
        case email
    }

    enum SourceScope: Hashable {
        case local
        case phone
        case icloud
    }

    enum DateScope: Hashable {
        case today
        case yesterday
    }

    let terms: [String]
    let types: Set<ItemType>
    let sources: Set<SourceScope>
    let dates: Set<DateScope>
    let favoritesOnly: Bool

    init(rawValue: String) {
        var parsedTerms: [String] = []
        var parsedTypes = Set<ItemType>()
        var parsedSources = Set<SourceScope>()
        var parsedDates = Set<DateScope>()
        var parsedFavoritesOnly = false

        for token in rawValue
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch trimmed {
            case "fav", "favorite", "favorites", "收藏":
                parsedFavoritesOnly = true
            case "today", "今天":
                parsedDates.insert(.today)
            case "yesterday", "昨天":
                parsedDates.insert(.yesterday)
            default:
                if let type = Self.parseTypeToken(trimmed) {
                    parsedTypes.insert(type)
                } else if let source = Self.parseSourceToken(trimmed) {
                    parsedSources.insert(source)
                } else {
                    parsedTerms.append(trimmed)
                }
            }
        }

        terms = parsedTerms
        types = parsedTypes
        sources = parsedSources
        dates = parsedDates
        favoritesOnly = parsedFavoritesOnly
    }

    func matches(_ item: ClipboardItem) -> Bool {
        if favoritesOnly, !item.isFavorite {
            return false
        }

        if !types.isEmpty, !types.contains(where: { matches($0, item: item) }) {
            return false
        }

        if !sources.isEmpty, !sources.contains(where: { matches($0, item: item) }) {
            return false
        }

        if !dates.isEmpty, !dates.contains(where: { matches($0, item: item) }) {
            return false
        }

        let haystack = item.searchableText
        return terms.allSatisfy { haystack.contains($0) }
    }

    private static func parseTypeToken(_ token: String) -> ItemType? {
        switch token {
        case "type:text", "is:text":
            return .text
        case "type:image", "type:img", "is:image":
            return .image
        case "type:file", "type:files", "is:file":
            return .file
        case "type:folder", "type:directory", "type:dir", "is:folder", "is:directory":
            return .folder
        case "type:code", "is:code":
            return .code
        case "type:url", "type:link", "is:url":
            return .url
        case "type:email", "type:mail", "is:email", "is:mail":
            return .email
        default:
            return nil
        }
    }

    private static func parseSourceToken(_ token: String) -> SourceScope? {
        switch token {
        case "source:mac", "source:local":
            return .local
        case "source:phone", "source:iphone", "source:universal":
            return .phone
        case "source:icloud", "source:cloud":
            return .icloud
        default:
            return nil
        }
    }

    private func matches(_ type: ItemType, item: ClipboardItem) -> Bool {
        switch type {
        case .text:
            return item.isPlainText
        case .image:
            return item.isImage || item.containsImageFiles
        case .file:
            return item.containsFiles
        case .folder:
            return item.containsFolders
        case .code:
            return item.isCode
        case .url:
            return item.isURL
        case .email:
            return item.isEmail
        }
    }

    private func matches(_ source: SourceScope, item: ClipboardItem) -> Bool {
        switch source {
        case .local:
            return item.source == .local
        case .phone:
            return item.source == .universalClipboard
        case .icloud:
            return item.source == .cloudKit
        }
    }

    private func matches(_ date: DateScope, item: ClipboardItem) -> Bool {
        let calendar = Calendar.current
        switch date {
        case .today:
            return calendar.isDateInToday(item.createdAt)
        case .yesterday:
            return calendar.isDateInYesterday(item.createdAt)
        }
    }
}
