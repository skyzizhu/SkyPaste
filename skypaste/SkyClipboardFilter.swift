import Foundation

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case folder
    case code
    case url
    case email
    case favorites

    var id: String { rawValue }

    static let fixedLeading: ClipboardFilter = .all
    static let fixedTrailing: ClipboardFilter = .favorites
    static let reorderableCases: [ClipboardFilter] = [.text, .image, .file, .folder, .code, .url, .email]
    static let defaultDisplayOrder: [ClipboardFilter] = [fixedLeading] + reorderableCases + [fixedTrailing]

    var isUserReorderable: Bool {
        Self.reorderableCases.contains(self)
    }

    static func normalizedReorderableOrder(_ filters: [ClipboardFilter]) -> [ClipboardFilter] {
        var seen = Set<ClipboardFilter>()
        let filtered = filters.filter { filter in
            filter.isUserReorderable && seen.insert(filter).inserted
        }

        let missing = reorderableCases.filter { !seen.contains($0) }
        return filtered + missing
    }

    static func displayOrder(from reorderableOrder: [ClipboardFilter]) -> [ClipboardFilter] {
        [fixedLeading] + normalizedReorderableOrder(reorderableOrder) + [fixedTrailing]
    }

    var title: String {
        switch self {
        case .all:
            return L10n.tr("filter.all")
        case .text:
            return L10n.tr("filter.text")
        case .image:
            return L10n.tr("filter.image")
        case .file:
            return L10n.tr("filter.file")
        case .folder:
            return L10n.tr("filter.folder")
        case .code:
            return L10n.tr("filter.code")
        case .url:
            return L10n.tr("filter.url")
        case .email:
            return L10n.tr("filter.email")
        case .favorites:
            return L10n.tr("filter.favorites")
        }
    }

    var symbolSystemName: String? {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .text:
            return "text.alignleft"
        case .image:
            return "photo"
        case .file:
            return "doc.fill"
        case .folder:
            return "folder.fill"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .url:
            return "link"
        case .email:
            return "envelope.fill"
        case .favorites:
            return "star.fill"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .favorites:
            return item.isFavorite
        case .all:
            return true
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
}
