import AppKit
import Foundation
import Testing
@testable import SkyPaste

@Suite("SkyPaste core models")
struct SkyPasteCoreModelTests {
    @Test func urlTextIsDetectedAsURLAndNotPlainText() {
        let item = ClipboardItem(
            content: .text("https://example.com/path"),
            fingerprint: "url"
        )

        #expect(item.isURL)
        #expect(!item.isPlainText)
        #expect(ClipboardFilter.url.matches(item))
        #expect(!ClipboardFilter.text.matches(item))
    }

    @Test func regularTextStaysPlainText() {
        let item = ClipboardItem(
            content: .text("Hello SkyPaste"),
            fingerprint: "text"
        )

        #expect(item.isPlainText)
        #expect(!item.isURL)
        #expect(!item.isCode)
        #expect(ClipboardFilter.text.matches(item))
    }

    @Test func codeLikeTextIsDetectedAsCode() {
        let item = ClipboardItem(
            content: .text("""
            func greet() {
                print(\"hello\")
            }
            """),
            fingerprint: "code"
        )

        #expect(item.isCode)
        #expect(ClipboardFilter.code.matches(item))
    }

    @Test func favoritesFilterMatchesOnlyFavoriteItems() {
        let item = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .text("Pinned note"),
            fingerprint: "favorite",
            isFavorite: true
        )

        #expect(item.isFavorite)
        #expect(ClipboardFilter.favorites.matches(item))
    }

    @Test func imageTitlePrefersExplicitName() {
        let item = ClipboardItem(
            content: .image(data: Data(), name: "Preview.png", originalByteCount: 2048, previewOnly: false),
            fingerprint: "image"
        )

        #expect(item.isImage)
        #expect(item.title == "Preview.png")
        #expect(ClipboardFilter.image.matches(item))
    }

    @Test func urlSubtitleUsesURLLabelInsteadOfRawLink() {
        let item = ClipboardItem(
            content: .text("https://example.com/path?q=1"),
            fingerprint: "url"
        )

        #expect(item.isURL)
        #expect(item.subtitle == L10n.tr("filter.url"))
        #expect(item.browserURL?.absoluteString == "https://example.com/path?q=1")
    }

    @Test func imageOptimizerPreservesUniversalClipboardSource() {
        let item = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .image(data: Data([0x1, 0x2, 0x3]), name: "shot.png", originalByteCount: 3, previewOnly: false),
            fingerprint: "img:test",
            source: .universalClipboard
        )

        let optimized = ClipboardImageOptimizer.memoryOptimizedItem(item)

        #expect(optimized.source == .universalClipboard)
    }

    @Test func singleFileClipboardItemUsesFileMetadata() {
        let item = ClipboardItem(
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/Report.pdf")], pasteboardPayload: nil),
            fingerprint: "file:/tmp/Report.pdf"
        )

        #expect(item.isFileCollection)
        #expect(item.singleFileSystemItemKind == .file)
        #expect(item.title == L10n.format("clipboard.file_single", "Report.pdf"))
        #expect(item.subtitle == L10n.format("clipboard.subtitle.file_path", "/tmp"))
        #expect(item.openActionTitle == L10n.tr("menu.open_file"))
        #expect(item.containingFolderURL?.path == "/tmp")
    }

    @Test func singleFolderClipboardItemUsesFolderMetadata() {
        let item = ClipboardItem(
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/SkyPaste Folder", isDirectory: true)], pasteboardPayload: nil),
            fingerprint: "file:/tmp/SkyPaste Folder"
        )

        #expect(item.isFileCollection)
        #expect(item.singleFileSystemItemKind == .folder)
        #expect(item.title == L10n.format("clipboard.folder_single", "SkyPaste Folder"))
        #expect(item.subtitle == L10n.format("clipboard.subtitle.folder_path", "/tmp"))
        #expect(item.openActionTitle == L10n.tr("menu.open_folder"))
    }

    @Test func multipleFolderClipboardItemUsesFolderCountMetadata() {
        let item = ClipboardItem(
            content: .fileURLs(urls: [
                URL(fileURLWithPath: "/tmp/Folder A", isDirectory: true),
                URL(fileURLWithPath: "/tmp/Folder B", isDirectory: true)
            ], pasteboardPayload: nil),
            fingerprint: "file:/tmp/Folder A|/tmp/Folder B"
        )

        #expect(item.title == L10n.format("clipboard.folder_count", 2))
        #expect(item.subtitle == L10n.format("clipboard.subtitle.folder_count", 2))
        #expect(item.openActionTitle == L10n.tr("menu.open_item"))
    }

    @Test func fileAndFolderFiltersMatchTheirOwnTypes() {
        let fileItem = ClipboardItem(
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/Report.pdf")], pasteboardPayload: nil),
            fingerprint: "file:/tmp/Report.pdf"
        )
        let folderItem = ClipboardItem(
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/SkyPaste Folder", isDirectory: true)], pasteboardPayload: nil),
            fingerprint: "file:/tmp/SkyPaste Folder"
        )
        let textItem = ClipboardItem(
            content: .text("hello"),
            fingerprint: "txt:hello"
        )

        #expect(ClipboardFilter.file.matches(fileItem))
        #expect(!ClipboardFilter.file.matches(folderItem))
        #expect(ClipboardFilter.folder.matches(folderItem))
        #expect(!ClipboardFilter.folder.matches(fileItem))
        #expect(!ClipboardFilter.file.matches(textItem))
        #expect(!ClipboardFilter.folder.matches(textItem))
    }

    @Test func filePasteboardPayloadRoundTripsThroughClipboardDecoder() {
        let url = URL(fileURLWithPath: "/tmp/Report.pdf")
        let payload = ClipboardFilePasteboardPayload(items: [
            ClipboardPasteboardItemPayload(entries: [
                ClipboardPasteboardEntryPayload(
                    type: NSPasteboard.PasteboardType.fileURL.rawValue,
                    storage: .string(url.absoluteString)
                ),
                ClipboardPasteboardEntryPayload(
                    type: "com.huaibor.skypaste.test-file-marker",
                    storage: .data(Data([0x1, 0x2, 0x3]))
                )
            ])
        ])

        let item = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .fileURLs(urls: [url], pasteboardPayload: payload),
            fingerprint: "file:\(url.path)",
            source: .local
        )

        let pasteboard = NSPasteboard.withUniqueName()
        ClipboardDecoder.write(item, to: pasteboard)

        let restoredItems = pasteboard.pasteboardItems ?? []
        #expect(restoredItems.count == 1)
        #expect(restoredItems.first?.string(forType: .fileURL) == url.absoluteString)
        #expect(restoredItems.first?.data(forType: NSPasteboard.PasteboardType("com.huaibor.skypaste.test-file-marker")) == Data([0x1, 0x2, 0x3]))

        let decoded = ClipboardDecoder.decode(from: pasteboard)
        guard case .item(let decodedItem) = decoded else {
            Issue.record("Expected file item after roundtrip decode")
            return
        }

        #expect(decodedItem.fileURLs == [url])
        #expect(decodedItem.filePasteboardPayload?.hasEntries == true)
        let markerEntry = decodedItem.filePasteboardPayload?.items
            .flatMap(\.entries)
            .first(where: { $0.type == "com.huaibor.skypaste.test-file-marker" })

        guard let markerEntry else {
            Issue.record("Expected custom file marker to survive payload roundtrip")
            return
        }

        #expect(markerEntry.storage == .data(Data([0x1, 0x2, 0x3])))
    }

    @Test func fileWriteAddsLegacyFinderFileListType() {
        let url = URL(fileURLWithPath: "/tmp/Report.pdf")
        let item = ClipboardItem(
            content: .fileURLs(urls: [url], pasteboardPayload: nil),
            fingerprint: "file:\(url.path)"
        )

        let pasteboard = NSPasteboard.withUniqueName()
        ClipboardDecoder.write(item, to: pasteboard)

        let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]
        #expect(filenames == [url.path])
    }

    @Test func fileSystemPreviewSnapshotListsImmediateDirectoryEntries() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedDirectory = rootDirectory.appendingPathComponent("Subdir", isDirectory: true)
        let topLevelFile = rootDirectory.appendingPathComponent("notes.txt")
        let nestedFile = nestedDirectory.appendingPathComponent("deep.txt")

        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data([0x1, 0x2, 0x3]).write(to: topLevelFile)
        try Data([0x4, 0x5, 0x6, 0x7]).write(to: nestedFile)
        defer {
            try? fileManager.removeItem(at: rootDirectory)
        }

        let item = ClipboardItem(
            content: .fileURLs(urls: [rootDirectory], pasteboardPayload: nil),
            fingerprint: "file:\(rootDirectory.path)"
        )

        let snapshot = FileSystemPreviewSnapshot.build(for: item)

        #expect(snapshot.kind == .folder)
        #expect(snapshot.itemCount == 2)
        #expect(snapshot.sizeBytes == 7)
        #expect(snapshot.directoryEntries.map(\.name) == ["Subdir", "notes.txt"])
        #expect(!snapshot.directoryEntries.map(\.name).contains("deep.txt"))
    }

    @Test func supportedLanguagesAreRecognized() {
        #expect(LanguageCatalog.isSupported("en"))
        #expect(LanguageCatalog.isSupported("zh-Hans"))
        #expect(LanguageCatalog.isSupported("zh-Hant"))
        #expect(LanguageCatalog.isSupported("ja"))
        #expect(LanguageCatalog.isSupported("ko"))
        #expect(LanguageCatalog.isSupported("fr"))
        #expect(!LanguageCatalog.isSupported("de"))
    }

    @Test func launchAtLoginRequiresApplicationsFolder() {
        let installedAppURL = URL(fileURLWithPath: "/Applications/SkyPaste.app", isDirectory: true)
        let userInstalledAppURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("SkyPaste.app", isDirectory: true)
        let derivedDataAppURL = URL(
            fileURLWithPath: "/Users/test/Library/Developer/Xcode/DerivedData/SkyPaste/Build/Products/Debug/SkyPaste.app",
            isDirectory: true
        )

        #expect(AppSettings.canConfigureLaunchAtLogin(for: installedAppURL))
        #expect(AppSettings.canConfigureLaunchAtLogin(for: userInstalledAppURL))
        #expect(!AppSettings.canConfigureLaunchAtLogin(for: derivedDataAppURL))
    }

    @Test func appearanceModesMapToExpectedAppKitAppearances() {
        #expect(AppAppearanceMode.system.nsAppearance == nil)
        #expect(AppAppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppAppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func cloudSyncUploadsOnlyLocalTextItems() {
        let localText = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .text("hello"),
            fingerprint: "txt:hello",
            source: .local
        )
        let universalText = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .text("hello"),
            fingerprint: "txt:hello",
            source: .universalClipboard
        )
        let localImage = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .image(data: Data([0x1]), name: nil, originalByteCount: 1, previewOnly: false),
            fingerprint: "img:1",
            source: .local
        )

        #expect(CloudClipboardSyncPolicy.shouldUpload(localText))
        #expect(!CloudClipboardSyncPolicy.shouldUpload(universalText))
        #expect(!CloudClipboardSyncPolicy.shouldUpload(localImage))
    }

    @Test func cloudSyncAppliesOnlyNewerIncomingItems() {
        let now = Date()
        let existing = ClipboardItem(
            id: UUID(),
            createdAt: now,
            content: .text("hello"),
            fingerprint: "txt:hello",
            source: .local
        )
        let olderIncoming = ClipboardItem(
            id: UUID(),
            createdAt: now.addingTimeInterval(-5),
            content: .text("hello"),
            fingerprint: "txt:hello",
            source: .cloudKit
        )
        let newerIncoming = ClipboardItem(
            id: UUID(),
            createdAt: now.addingTimeInterval(5),
            content: .text("hello"),
            fingerprint: "txt:hello",
            source: .cloudKit
        )

        #expect(!CloudClipboardSyncPolicy.shouldApplyIncoming(olderIncoming, over: existing))
        #expect(CloudClipboardSyncPolicy.shouldApplyIncoming(newerIncoming, over: existing))
    }

    @Test func cloudSyncBackfillCandidatesIncludeOnlyLocalTextInAscendingDateOrder() {
        let now = Date()
        let newestLocalText = ClipboardItem(
            id: UUID(),
            createdAt: now,
            content: .text("Newest"),
            fingerprint: "txt:newest",
            source: .local
        )
        let oldestLocalText = ClipboardItem(
            id: UUID(),
            createdAt: now.addingTimeInterval(-20),
            content: .text("Oldest"),
            fingerprint: "txt:oldest",
            source: .local
        )
        let universalText = ClipboardItem(
            id: UUID(),
            createdAt: now.addingTimeInterval(-10),
            content: .text("Phone"),
            fingerprint: "txt:phone",
            source: .universalClipboard
        )
        let localImage = ClipboardItem(
            id: UUID(),
            createdAt: now.addingTimeInterval(-5),
            content: .image(data: Data([0x1]), name: nil, originalByteCount: 1, previewOnly: false),
            fingerprint: "img:1",
            source: .local
        )

        let candidates = CloudClipboardSyncPolicy.backfillUploadCandidates(
            from: [newestLocalText, universalText, oldestLocalText, localImage]
        )

        #expect(candidates.map(\.fingerprint) == ["txt:oldest", "txt:newest"])
    }

    @Test func cloudSyncRecordNameIsStablePerFingerprint() {
        let first = SkyCloudClipboardSchema.recordName(for: "txt:hello")
        let second = SkyCloudClipboardSchema.recordName(for: "txt:hello")
        let different = SkyCloudClipboardSchema.recordName(for: "txt:world")

        #expect(first == second)
        #expect(first != different)
        #expect(first.hasPrefix("clip-"))
    }

    @Test func cloudSyncFetchQueryUsesCreatedAtInsteadOfRecordName() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let query = CloudClipboardSyncManager.makeFetchQuery(since: cutoff)

        let predicateFormat = query.predicate.predicateFormat
        #expect(predicateFormat.contains(SkyCloudClipboardSchema.Field.createdAt))
        #expect(!predicateFormat.localizedCaseInsensitiveContains("recordName"))
        #expect(query.sortDescriptors?.first?.key == SkyCloudClipboardSchema.Field.createdAt)
    }

    @Test func searchQueryMatchesFullTextAndStructuredTokens() {
        let item = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .text("""
            This is a longer note about project launch readiness and rollout details.
            """),
            fingerprint: "txt:search",
            source: .cloudKit
        )

        #expect(ClipboardSearchQuery(rawValue: "rollout").matches(item))
        #expect(ClipboardSearchQuery(rawValue: "type:text source:icloud").matches(item))
        #expect(!ClipboardSearchQuery(rawValue: "type:image").matches(item))
        #expect(!ClipboardSearchQuery(rawValue: "source:phone").matches(item))
    }

    @Test func searchQueryMatchesStructuredFileTokens() {
        let item = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/Contracts", isDirectory: true)], pasteboardPayload: nil),
            fingerprint: "file:/tmp/Contracts",
            source: .local
        )

        #expect(!ClipboardSearchQuery(rawValue: "type:file").matches(item))
        #expect(ClipboardSearchQuery(rawValue: "type:folder").matches(item))
        #expect(!ClipboardSearchQuery(rawValue: "type:image").matches(item))
    }

    @Test func searchQueryMatchesFavoritesAndRelativeDates() {
        let favoriteItem = ClipboardItem(
            id: UUID(),
            createdAt: Date(),
            content: .text("Pinned note"),
            fingerprint: "txt:pinned",
            source: .local,
            isFavorite: true
        )
        let oldItem = ClipboardItem(
            id: UUID(),
            createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            content: .text("Yesterday note"),
            fingerprint: "txt:yesterday",
            source: .local
        )

        #expect(ClipboardSearchQuery(rawValue: "fav today").matches(favoriteItem))
        #expect(!ClipboardSearchQuery(rawValue: "fav").matches(oldItem))
        #expect(ClipboardSearchQuery(rawValue: "yesterday").matches(oldItem))
    }

}
