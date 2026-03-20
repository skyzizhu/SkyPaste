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

    @Test func supportedLanguagesAreRecognized() {
        #expect(LanguageCatalog.isSupported("en"))
        #expect(LanguageCatalog.isSupported("zh-Hans"))
        #expect(LanguageCatalog.isSupported("zh-Hant"))
        #expect(LanguageCatalog.isSupported("ja"))
        #expect(LanguageCatalog.isSupported("ko"))
        #expect(LanguageCatalog.isSupported("fr"))
        #expect(!LanguageCatalog.isSupported("de"))
    }
}
