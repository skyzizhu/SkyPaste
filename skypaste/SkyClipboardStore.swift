import AppKit
import Combine
import Foundation

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var filteredItems: [ClipboardItem] = []
    @Published private(set) var filteredItemsByFilter: [ClipboardFilter: [ClipboardItem]] = [:]
    @Published private(set) var sourceAppOptionsByFilter: [ClipboardFilter: [ClipboardSourceAppOption]] = [:]
    @Published private(set) var appliedSearchText: String = ""
    @Published var startupNotice: String?
    var onLocalItemAdded: ((ClipboardItem) -> Void)?

    private let settings: AppSettings
    private let database: ClipboardDatabase?
    private let filterQueue = DispatchQueue(label: "com.huaibor.skypaste.search-filter", qos: .userInitiated)
    private let databaseWriteQueue = DispatchQueue(label: "com.huaibor.skypaste.database-write", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    private var filterWorkItem: DispatchWorkItem?
    private var filterGeneration: Int = 0
    private var suppressNextItemsFilterUpdate = false

    init(settings: AppSettings) {
        self.settings = settings
        let initialization = Self.makeDatabase()
        self.database = initialization.database
        self.startupNotice = initialization.notice

        if let database {
            do {
                try database.clearAllSnippets()
                items = try database.loadVisibleItems(historyLimit: settings.historyLimit).map { item in
                    var item = item
                    item.isSnippet = false
                    return ClipboardImageOptimizer.memoryOptimizedItem(item)
                }
            } catch {
                print("[ClipboardStore] Failed to load history: \(error)")
            }
        }

        filteredItemsByFilter = Self.makeFilteredItemsByFilter(items: items, query: "")
        sourceAppOptionsByFilter = Self.makeSourceAppOptionsByFilter(itemsByFilter: filteredItemsByFilter)
        filteredItems = filteredItemsByFilter[.all] ?? items

        settings.$historyLimit
            .removeDuplicates()
            .sink { [weak self] newLimit in
                self?.applyHistoryLimit(newLimit)
            }
            .store(in: &cancellables)

        $items
            .sink { [weak self] items in
                guard let self else { return }
                if self.suppressNextItemsFilterUpdate {
                    self.suppressNextItemsFilterUpdate = false
                    return
                }
                self.updateFilteredItems(items: items, query: self.appliedSearchText)
            }
            .store(in: &cancellables)

    }

    func itemsEligibleForCloudSync() -> [ClipboardItem] {
        CloudClipboardSyncPolicy.backfillUploadCandidates(from: items)
    }

    func add(_ item: ClipboardItem) {
        var item = item
        guard !shouldFilterSensitiveContent(item) else { return }
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
        guard !shouldFilterSensitiveContent(item) else { return }
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
        case .item(let decodedItem):
            var decodedItem = decodedItem
            if decodedItem.source == .local, !acceptsLocalContent {
                guard items.first?.fingerprint != decodedItem.fingerprint else { return }
                // Universal Clipboard can arrive without a pasteboard changeCount bump or a stable remote marker.
                decodedItem = decodedItem.withSource(.universalClipboard)
            }
            if decodedItem.source == .universalClipboard, !settings.receiveUniversalClipboardEnabled {
                return
            }
            if decodedItem.source == .local, !acceptsLocalContent {
                return
            }
            if decodedItem.source == .local, shouldIgnoreCurrentFrontApp() {
                return
            }
            let item = attachCurrentFrontmostSourceApp(to: decodedItem)
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
                if !newValue {
                    try database.trimToLimit(settings.historyLimit)
                }
            } catch {
                print("[ClipboardStore] Failed to update favorite: \(error)")
                return
            }
        }

        var updatedItems = items
        updatedItems[index].isFavorite = newValue
        replaceItemsForImmediateDisplay(applyingHistoryLimit(to: updatedItems))
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

        replaceItemsForImmediateDisplay(items.filter { $0.id != itemID })
    }

    func deleteItems(_ itemIDs: Set<ClipboardItem.ID>) {
        guard !itemIDs.isEmpty else { return }

        let remainingItems = items.filter { !itemIDs.contains($0.id) }
        replaceItemsForImmediateDisplay(remainingItems)

        guard let fileURL = database?.fileURL else { return }
        let idsToDelete = Array(itemIDs)
        databaseWriteQueue.async {
            do {
                try ClipboardDatabase.deleteItems(ids: idsToDelete, in: fileURL)
            } catch {
                print("[ClipboardStore] Failed to delete selected items: \(error)")
            }
        }
    }

    func deleteAllItems(onDay day: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        var idsToDelete: [UUID] = []
        let remainingItems = items.filter { item in
            let shouldDelete = item.createdAt >= start && item.createdAt < end
            if shouldDelete {
                idsToDelete.append(item.id)
            }
            return !shouldDelete
        }
        guard !idsToDelete.isEmpty else { return }

        replaceItemsForImmediateDisplay(remainingItems)

        guard let fileURL = database?.fileURL else { return }
        databaseWriteQueue.async {
            do {
                try ClipboardDatabase.deleteItems(ids: idsToDelete, in: fileURL)
            } catch {
                print("[ClipboardStore] Failed to delete day items: \(error)")
            }
        }
    }

    func setFavorite(_ isFavorite: Bool, for itemIDs: Set<ClipboardItem.ID>) {
        guard !itemIDs.isEmpty else { return }

        var updatedItems = items
        for index in updatedItems.indices where itemIDs.contains(updatedItems[index].id) {
            updatedItems[index].isFavorite = isFavorite
        }

        replaceItemsForImmediateDisplay(applyingHistoryLimit(to: updatedItems))

        guard let fileURL = database?.fileURL else { return }
        let idsToUpdate = Array(itemIDs)
        let historyLimit = isFavorite ? nil : settings.historyLimit
        databaseWriteQueue.async {
            do {
                try ClipboardDatabase.setFavorites(isFavorite, forIDs: idsToUpdate, in: fileURL, maxItems: historyLimit)
            } catch {
                print("[ClipboardStore] Failed to update selected favorites: \(error)")
            }
        }
    }

    func dismissStartupNotice() {
        startupNotice = nil
    }

    func setSearchQuery(_ query: String) {
        updateFilteredItems(items: items, query: query)
    }

    func items(for filter: ClipboardFilter) -> [ClipboardItem] {
        filteredItemsByFilter[filter] ?? []
    }

    func sourceAppOptions(for filter: ClipboardFilter) -> [ClipboardSourceAppOption] {
        sourceAppOptionsByFilter[filter] ?? []
    }

    private func replaceItemsForImmediateDisplay(_ newItems: [ClipboardItem]) {
        suppressNextItemsFilterUpdate = true
        items = newItems
        updateFilteredItems(items: newItems, query: appliedSearchText)
    }

    private func shouldIgnoreCurrentFrontApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let candidates = [
            app.bundleIdentifier,
            app.localizedName
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

        return candidates.contains { settings.ignoredApps.contains($0) }
    }

    private func shouldFilterSensitiveContent(_ item: ClipboardItem) -> Bool {
        guard settings.privacyContentFilteringEnabled else {
            return false
        }

        return SensitiveClipboardContentFilter.shouldExclude(item)
    }

    private func attachCurrentFrontmostSourceApp(to item: ClipboardItem) -> ClipboardItem {
        guard item.source == .local else { return item }

        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty
        else {
            return item.withSourceApp(nil)
        }

        let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return item.withSourceApp(nil)
        }

        return item.withSourceApp(ClipboardSourceApp(bundleID: bundleID, name: name))
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

    private func updateFilteredItems(items: [ClipboardItem], query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedSearchText = trimmedQuery
        filterGeneration += 1
        let generation = filterGeneration

        filterWorkItem?.cancel()

        guard !trimmedQuery.isEmpty else {
            filteredItemsByFilter = Self.makeFilteredItemsByFilter(items: items, query: "")
            sourceAppOptionsByFilter = Self.makeSourceAppOptionsByFilter(itemsByFilter: filteredItemsByFilter)
            filteredItems = filteredItemsByFilter[.all] ?? items
            return
        }

        let snapshot = items
        let workItem = DispatchWorkItem { [trimmedQuery] in
            let result = Self.makeFilteredItemsByFilter(items: snapshot, query: trimmedQuery)
            let sourceAppOptions = Self.makeSourceAppOptionsByFilter(itemsByFilter: result)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.filterGeneration == generation else { return }
                self.filteredItemsByFilter = result
                self.sourceAppOptionsByFilter = sourceAppOptions
                self.filteredItems = result[.all] ?? []
            }
        }

        filterWorkItem = workItem
        filterQueue.async(execute: workItem)
    }

    private static func makeFilteredItemsByFilter(items: [ClipboardItem], query: String) -> [ClipboardFilter: [ClipboardItem]] {
        let parsedQuery = query.isEmpty ? nil : ClipboardSearchQuery(rawValue: query)
        var result = Dictionary(uniqueKeysWithValues: ClipboardFilter.allCases.map { ($0, [ClipboardItem]()) })

        for item in items {
            guard parsedQuery?.matches(item) ?? true else { continue }

            result[.all, default: []].append(item)

            if item.isFavorite {
                result[.favorites, default: []].append(item)
            }
            if ClipboardFilter.text.matches(item) {
                result[.text, default: []].append(item)
            }
            if ClipboardFilter.image.matches(item) {
                result[.image, default: []].append(item)
            }
            if ClipboardFilter.file.matches(item) {
                result[.file, default: []].append(item)
            }
            if ClipboardFilter.folder.matches(item) {
                result[.folder, default: []].append(item)
            }
            if ClipboardFilter.code.matches(item) {
                result[.code, default: []].append(item)
            }
            if ClipboardFilter.url.matches(item) {
                result[.url, default: []].append(item)
            }
            if ClipboardFilter.email.matches(item) {
                result[.email, default: []].append(item)
            }
        }

        return result
    }

    private static func makeSourceAppOptionsByFilter(itemsByFilter: [ClipboardFilter: [ClipboardItem]]) -> [ClipboardFilter: [ClipboardSourceAppOption]] {
        var result = [ClipboardFilter: [ClipboardSourceAppOption]]()

        for filter in ClipboardFilter.allCases {
            var seen = Set<String>()
            let options = (itemsByFilter[filter] ?? [])
                .compactMap(\.sourceApp)
                .compactMap { app -> ClipboardSourceAppOption? in
                    guard seen.insert(app.bundleID).inserted else { return nil }
                    return ClipboardSourceAppOption(bundleID: app.bundleID, name: app.name)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            result[filter] = options
        }

        return result
    }

    private func enforceHistoryLimit(limit: Int? = nil) {
        items = applyingHistoryLimit(to: items, limit: limit)
    }

    private func applyingHistoryLimit(to sourceItems: [ClipboardItem], limit: Int? = nil) -> [ClipboardItem] {
        let resolvedLimit = max(0, limit ?? settings.historyLimit)
        guard resolvedLimit > 0 else {
            return sourceItems.filter(\.isFavorite)
        }

        var result: [ClipboardItem] = []
        result.reserveCapacity(min(sourceItems.count, resolvedLimit))

        var nonFavoriteCount = 0
        for item in sourceItems {
            if item.isFavorite {
                result.append(item)
                continue
            }

            guard nonFavoriteCount < resolvedLimit else { continue }
            result.append(item)
            nonFavoriteCount += 1
        }

        return result
    }
}

enum SensitiveClipboardContentFilter {
    private static let knownPasswordManagerFragments = [
        "1password",
        "agilebits",
        "bitwarden",
        "lastpass",
        "dashlane",
        "keeper",
        "enpass",
        "strongbox",
        "keychain access"
    ]

    private static let tokenPrefixes = [
        "sk-",
        "rk-",
        "ghp_",
        "github_pat_",
        "xoxb-",
        "xoxp-",
        "ya29.",
        "akia",
        "aiza",
        "bearer "
    ]

    static func shouldExclude(_ item: ClipboardItem) -> Bool {
        guard case .text(let rawText) = item.content else {
            return false
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }

        if matchesKnownPasswordManager(item.sourceApp) {
            return true
        }

        return isVerificationCode(text)
            || isBankCardNumber(text)
            || isSensitiveToken(text)
    }

    private static func matchesKnownPasswordManager(_ sourceApp: ClipboardSourceApp?) -> Bool {
        guard let sourceApp else { return false }
        let haystack = [sourceApp.bundleID, sourceApp.name]
            .map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            .joined(separator: " ")

        return knownPasswordManagerFragments.contains { haystack.contains($0) }
    }

    private static func isVerificationCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(trimmed, pattern: #"^\d{4,8}$"#) {
            return true
        }

        if matches(trimmed, pattern: #"^[A-Z0-9]{4,8}$"#) {
            return true
        }

        return matches(
            trimmed,
            pattern: #"(?i)(验证码|驗證碼|verification code|security code|otp|one[- ]time password)[^0-9A-Z]{0,12}[0-9A-Z]{4,8}"#
        )
    }

    private static func isBankCardNumber(_ text: String) -> Bool {
        let digits = text.unicodeScalars
            .filter(CharacterSet.decimalDigits.contains)
            .map(String.init)
            .joined()

        guard (13...19).contains(digits.count), luhnCheck(digits) else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "0123456789 -")
        return text.unicodeScalars.allSatisfy { allowed.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isSensitiveToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if tokenPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        if matches(trimmed, pattern: #"^-----BEGIN [A-Z ]*PRIVATE KEY-----"#) {
            return true
        }

        if matches(trimmed, pattern: #"^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$"#) {
            return true
        }

        if matches(lowercased, pattern: #"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|secret[_ -]?key|client[_ -]?secret|private[_ -]?key|token)[:= ]+[A-Za-z0-9_\-\/+=]{12,}"#) {
            return true
        }

        return matches(trimmed, pattern: #"^[A-Za-z0-9_\-\/+=]{32,}$"#)
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func luhnCheck(_ digits: String) -> Bool {
        var sum = 0
        let reversedDigits = digits.reversed().compactMap { $0.wholeNumberValue }

        for (index, digit) in reversedDigits.enumerated() {
            if index.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }

        return sum > 0 && sum.isMultiple(of: 10)
    }
}

final class ClipboardMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.huaibor.skypaste.clipboard-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = 0
    private var lastLocalChangeDate = Date.distantPast
    private var lastRemoteProbeDate = Date.distantPast
    private var scheduledPollInterval: TimeInterval = 0
    private let activePollInterval: TimeInterval = 0.35
    private let idlePollInterval: TimeInterval = 1.0
    private let activeRemoteProbeInterval: TimeInterval = 1.5
    private let idleRemoteProbeInterval: TimeInterval = 4.0
    private let activePollingWindow: TimeInterval = 8.0
    private let onChange: (_ acceptsLocalContent: Bool) -> Void

    init(onChange: @escaping (_ acceptsLocalContent: Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        lastChangeCount = currentPasteboardChangeCount()
        lastLocalChangeDate = Date()
        lastRemoteProbeDate = Date.distantPast

        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        rescheduleTimer(for: Date())
        timer.setEventHandler { [weak self] in
            self?.pollPasteboard()
        }
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        scheduledPollInterval = 0
    }

    private func pollPasteboard() {
        let now = Date()
        let currentCount = currentPasteboardChangeCount()

        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            lastLocalChangeDate = now
            lastRemoteProbeDate = now
            onChange(true)
            rescheduleTimer(for: now)
            return
        }

        let remoteProbeInterval = currentRemoteProbeInterval(for: now)
        guard now.timeIntervalSince(lastRemoteProbeDate) >= remoteProbeInterval else {
            rescheduleTimer(for: now)
            return
        }

        lastRemoteProbeDate = now
        onChange(false)
        rescheduleTimer(for: now)
    }

    private func currentPasteboardChangeCount() -> Int {
        if Thread.isMainThread {
            return NSPasteboard.general.changeCount
        }

        return DispatchQueue.main.sync {
            NSPasteboard.general.changeCount
        }
    }

    private func currentPollInterval(for date: Date) -> TimeInterval {
        isInActivePollingWindow(at: date) ? activePollInterval : idlePollInterval
    }

    private func currentRemoteProbeInterval(for date: Date) -> TimeInterval {
        isInActivePollingWindow(at: date) ? activeRemoteProbeInterval : idleRemoteProbeInterval
    }

    private func isInActivePollingWindow(at date: Date) -> Bool {
        date.timeIntervalSince(lastLocalChangeDate) < activePollingWindow
    }

    private func rescheduleTimer(for date: Date) {
        let interval = currentPollInterval(for: date)
        guard scheduledPollInterval != interval else { return }

        scheduledPollInterval = interval
        let leeway = interval >= 1 ? DispatchTimeInterval.milliseconds(300) : DispatchTimeInterval.milliseconds(120)
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
    }
}
