import AppKit
import Combine
import Foundation

struct ClipboardSearchQuery {
    enum ItemType: Hashable {
        case text
        case image
        case url
        case code
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
        case "type:url", "type:link", "is:url":
            return .url
        case "type:code", "is:code":
            return .code
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
            return item.isImage
        case .url:
            return item.isURL
        case .code:
            return item.isCode
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

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchText: String = ""
    @Published var startupNotice: String?
    var onLocalItemAdded: ((ClipboardItem) -> Void)?

    private let settings: AppSettings
    private let database: ClipboardDatabase?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        let initialization = Self.makeDatabase()
        self.database = initialization.database
        self.startupNotice = initialization.notice

        if let database {
            do {
                try database.clearAllSnippets()
                items = try database.loadRecent(limit: settings.historyLimit).map { item in
                    var item = item
                    item.isSnippet = false
                    return ClipboardImageOptimizer.memoryOptimizedItem(item)
                }
            } catch {
                print("[ClipboardStore] Failed to load history: \(error)")
            }
        }

        settings.$historyLimit
            .removeDuplicates()
            .sink { [weak self] newLimit in
                self?.applyHistoryLimit(newLimit)
            }
            .store(in: &cancellables)
    }

    var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let parsedQuery = ClipboardSearchQuery(rawValue: query)
        return items.filter { parsedQuery.matches($0) }
    }

    func add(_ item: ClipboardItem) {
        var item = item
        item.isFavorite = preservedFavoriteState(for: item)
        item.isSnippet = false

        let memoryItem = ClipboardImageOptimizer.memoryOptimizedItem(item)

        if let first = items.first, first.fingerprint == item.fingerprint {
            if shouldRefreshTopItem(current: first, incoming: memoryItem) {
                persist(item)
                items[0] = memoryItem
                if item.source == .local {
                    onLocalItemAdded?(item)
                }
            }
            return
        }

        persist(item)

        items.removeAll { $0.fingerprint == memoryItem.fingerprint }
        items.insert(memoryItem, at: 0)
        enforceHistoryLimit()

        if item.source == .local {
            onLocalItemAdded?(item)
        }
    }

    func addCloudSyncedItem(_ item: ClipboardItem) {
        var item = item
        item.isFavorite = preservedFavoriteState(for: item)
        item.isSnippet = false

        let existingItem = items.first { $0.fingerprint == item.fingerprint }
        guard CloudClipboardSyncPolicy.shouldApplyIncoming(item, over: existingItem) else {
            return
        }

        persist(item)

        let memoryItem = ClipboardImageOptimizer.memoryOptimizedItem(item)
        items.removeAll { $0.fingerprint == memoryItem.fingerprint }

        let insertionIndex = items.firstIndex { existing in
            existing.createdAt < memoryItem.createdAt
        } ?? items.endIndex
        items.insert(memoryItem, at: insertionIndex)
        enforceHistoryLimit()
    }

    func captureCurrentPasteboardIfNeeded(acceptsLocalContent: Bool = true) {
        switch ClipboardDecoder.decode(from: NSPasteboard.general) {
        case .none:
            return
        case .item(let item):
            if item.source == .universalClipboard, !settings.receiveUniversalClipboardEnabled {
                return
            }
            if item.source == .local, !acceptsLocalContent {
                return
            }
            if item.source == .local, shouldIgnoreCurrentFrontApp() {
                return
            }
            add(item)
        }
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        if let resolved = fullResolutionItemIfNeeded(for: item) {
            ClipboardDecoder.write(resolved, to: NSPasteboard.general)
            return
        }

        ClipboardDecoder.write(item, to: NSPasteboard.general)
    }

    func itemForPreview(_ item: ClipboardItem) -> ClipboardItem {
        fullResolutionItemIfNeeded(for: item) ?? item
    }

    func toggleFavorite(for itemID: ClipboardItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let newValue = !items[index].isFavorite

        if let database {
            do {
                try database.setFavorite(newValue, forID: itemID)
            } catch {
                print("[ClipboardStore] Failed to update favorite: \(error)")
                return
            }
        }

        items[index].isFavorite = newValue
    }

    func deleteItem(_ itemID: ClipboardItem.ID) {
        if let database {
            do {
                try database.deleteItem(id: itemID)
            } catch {
                print("[ClipboardStore] Failed to delete item: \(error)")
                return
            }
        }

        items.removeAll { $0.id == itemID }
    }

    func deleteAllItems(onDay day: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        items.removeAll { item in
            item.createdAt >= start && item.createdAt < end
        }

        guard let database else { return }
        do {
            try database.deleteCreatedAtRange(from: start, to: end)
        } catch {
            print("[ClipboardStore] Failed to delete day items: \(error)")
        }
    }

    func dismissStartupNotice() {
        startupNotice = nil
    }

    private func shouldIgnoreCurrentFrontApp() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return settings.ignoredBundleIDs.contains(front)
    }

    private func persist(_ item: ClipboardItem) {
        guard let database else { return }

        do {
            try database.save(item, maxItems: settings.historyLimit)
        } catch {
            print("[ClipboardStore] Failed to persist history: \(error)")
        }
    }

    private func applyHistoryLimit(_ limit: Int) {
        enforceHistoryLimit(limit: limit)

        guard let database else { return }

        do {
            try database.trimToLimit(limit)
        } catch {
            print("[ClipboardStore] Failed to trim history: \(error)")
        }
    }

    private func preservedFavoriteState(for item: ClipboardItem) -> Bool {
        if let existing = items.first(where: { $0.fingerprint == item.fingerprint }) {
            return existing.isFavorite
        }

        guard let database else { return item.isFavorite }

        do {
            return try database.favoriteState(forFingerprint: item.fingerprint) ?? item.isFavorite
        } catch {
            print("[ClipboardStore] Failed to load favorite state: \(error)")
            return item.isFavorite
        }
    }

    private func shouldRefreshTopItem(current: ClipboardItem, incoming: ClipboardItem) -> Bool {
        current.source != incoming.source ||
            current.title != incoming.title ||
            current.subtitle != incoming.subtitle ||
            current.isFavorite != incoming.isFavorite
    }

    private func fullResolutionItemIfNeeded(for item: ClipboardItem) -> ClipboardItem? {
        guard case .image(_, _, _, let previewOnly) = item.content, previewOnly else {
            return nil
        }

        guard let database else { return item }

        do {
            return try database.loadItem(id: item.id) ?? item
        } catch {
            print("[ClipboardStore] Failed to load full-resolution image: \(error)")
            return item
        }
    }

    private struct DatabaseInitializationResult {
        let database: ClipboardDatabase?
        let notice: String?
    }

    private static func makeDatabase() -> DatabaseInitializationResult {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDir = baseDir.appendingPathComponent("SkyPaste", isDirectory: true)
        let dbURL = appDir.appendingPathComponent("history.sqlite", isDirectory: false)
        let legacyDir = baseDir.appendingPathComponent("mac-pastenow-clone", isDirectory: true)
        let legacyDBURL = legacyDir.appendingPathComponent("history.sqlite", isDirectory: false)

        do {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: dbURL.path), fileManager.fileExists(atPath: legacyDBURL.path) {
                try fileManager.copyItem(at: legacyDBURL, to: dbURL)
            }
            return DatabaseInitializationResult(database: try ClipboardDatabase(fileURL: dbURL), notice: nil)
        } catch {
            if recoverCorruptedDatabaseIfNeeded(error, fileURL: dbURL, fileManager: fileManager) {
                do {
                    return DatabaseInitializationResult(
                        database: try ClipboardDatabase(fileURL: dbURL),
                        notice: L10n.tr("notice.database_recovered")
                    )
                } catch {
                    print("[ClipboardStore] Failed to initialize recovered db: \(error)")
                    return DatabaseInitializationResult(database: nil, notice: nil)
                }
            }

            print("[ClipboardStore] Failed to initialize db: \(error)")
            return DatabaseInitializationResult(database: nil, notice: nil)
        }
    }

    private static func recoverCorruptedDatabaseIfNeeded(_ error: Error, fileURL: URL, fileManager: FileManager) -> Bool {
        guard isDatabaseCorruption(error) else { return false }

        let timestamp = Self.recoveryTimestampFormatter.string(from: Date())
        let backupDir = fileURL.deletingLastPathComponent().appendingPathComponent("RecoveredDatabases", isDirectory: true)

        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

            for candidate in sqliteSidecarURLs(for: fileURL) where fileManager.fileExists(atPath: candidate.path) {
                let backupURL = backupDir.appendingPathComponent(candidate.lastPathComponent + ".\(timestamp).bak")
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: candidate, to: backupURL)
                try fileManager.removeItem(at: candidate)
            }

            print("[ClipboardStore] Recovered corrupted database. Backup saved under \(backupDir.path)")
            return true
        } catch {
            print("[ClipboardStore] Failed to recover corrupted database: \(error)")
            return false
        }
    }

    private static func isDatabaseCorruption(_ error: Error) -> Bool {
        if let dbError = error as? ClipboardDatabaseError {
            switch dbError {
            case .corruptionDetected:
                return true
            case .openFailed(let message), .prepareFailed(let message), .stepFailed(let message):
                return ClipboardDatabase.looksLikeCorruption(message)
            }
        }

        return ClipboardDatabase.looksLikeCorruption(String(describing: error))
    }

    private static func sqliteSidecarURLs(for fileURL: URL) -> [URL] {
        [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm")
        ]
    }

    private static let recoveryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func enforceHistoryLimit(limit: Int? = nil) {
        let resolvedLimit = limit ?? settings.historyLimit
        items = Array(items.prefix(resolvedLimit))
    }
}

final class ClipboardMonitor: @unchecked Sendable {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastRemoteProbeDate = Date.distantPast
    private let remoteProbeInterval: TimeInterval = 1.5
    private let onChange: (_ acceptsLocalContent: Bool) -> Void

    init(onChange: @escaping (_ acceptsLocalContent: Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            let currentCount = NSPasteboard.general.changeCount
            if currentCount != self.lastChangeCount {
                self.lastChangeCount = currentCount
                self.lastRemoteProbeDate = Date()
                self.onChange(true)
                return
            }

            let now = Date()
            guard now.timeIntervalSince(self.lastRemoteProbeDate) >= self.remoteProbeInterval else { return }
            self.lastRemoteProbeDate = now
            self.onChange(false)
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

}
