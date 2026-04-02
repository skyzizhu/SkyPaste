import AppKit
import Combine
import Foundation

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchText: String = ""

    private let settings: AppSettings
    private let database: ClipboardDatabase?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        self.database = Self.makeDatabase()

        if let database {
            do {
                items = try database.loadRecent(limit: settings.historyLimit).map(ClipboardImageOptimizer.memoryOptimizedItem)
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
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func add(_ item: ClipboardItem) {
        var item = item
        item.isFavorite = preservedFavoriteState(for: item)

        let memoryItem = ClipboardImageOptimizer.memoryOptimizedItem(item)

        if let first = items.first, first.fingerprint == item.fingerprint {
            if shouldRefreshTopItem(current: first, incoming: memoryItem) {
                persist(item)
                items[0] = memoryItem
            }
            return
        }

        persist(item)

        items.removeAll { $0.fingerprint == memoryItem.fingerprint }
        items.insert(memoryItem, at: 0)

        if items.count > settings.historyLimit {
            items.removeLast(items.count - settings.historyLimit)
        }
    }

    func captureCurrentPasteboardIfNeeded() {
        switch ClipboardDecoder.decode(from: NSPasteboard.general) {
        case .none:
            return
        case .item(let item):
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
        if items.count > limit {
            items.removeLast(items.count - limit)
        }

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

    private static func makeDatabase() -> ClipboardDatabase? {
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
            return try ClipboardDatabase(fileURL: dbURL)
        } catch {
            print("[ClipboardStore] Failed to initialize db: \(error)")
            return nil
        }
    }
}

final class ClipboardMonitor: @unchecked Sendable {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            let currentCount = NSPasteboard.general.changeCount
            guard currentCount != self.lastChangeCount else { return }
            self.lastChangeCount = currentCount
            self.onChange()
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
