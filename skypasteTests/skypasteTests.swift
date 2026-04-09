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

    @Test func cloudSyncRecordNameIsStablePerFingerprint() {
        let first = SkyCloudClipboardSchema.recordName(for: "txt:hello")
        let second = SkyCloudClipboardSchema.recordName(for: "txt:hello")
        let different = SkyCloudClipboardSchema.recordName(for: "txt:world")

        #expect(first == second)
        #expect(first != different)
        #expect(first.hasPrefix("clip-"))
    }
}
