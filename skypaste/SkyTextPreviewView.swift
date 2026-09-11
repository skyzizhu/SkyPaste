import AppKit
import SwiftUI

struct TextPreviewView: View {
    @ObservedObject var store: ClipboardStore
    let item: ClipboardItem
    let text: String
    let onCopy: () -> Void
    let onOpenURL: (() -> Void)?
    let onOpenEmail: (() -> Void)?

    private var currentItem: ClipboardItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    private var headerActions: [PreviewHeaderAction] {
        var actions = [
            PreviewHeaderAction(
                title: currentItem.isURL ? L10n.tr("menu.copy_link") : L10n.tr("menu.copy"),
                systemImage: "doc.on.doc",
                action: onCopy
            )
        ]

        if let onOpenURL {
            actions.append(
                PreviewHeaderAction(
                    title: L10n.tr("menu.open_in_browser"),
                    systemImage: "safari",
                    action: onOpenURL
                )
            )
        }

        if let onOpenEmail {
            actions.append(
                PreviewHeaderAction(
                    title: L10n.tr("menu.open_email"),
                    systemImage: "envelope",
                    action: onOpenEmail
                )
            )
        }

        return actions
    }

    private var previewTitle: String {
        if currentItem.isEmail {
            return L10n.tr("preview.email_title")
        }

        if currentItem.isURL {
            return L10n.tr("preview.url_title")
        }

        if currentItem.isCode {
            return L10n.tr("preview.code_title")
        }

        return L10n.tr("preview.text_title")
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeaderView(
                title: previewTitle,
                secondaryText: currentItem.subtitle,
                item: currentItem
            ) {
                HStack(spacing: 8) {
                    PreviewHeaderFavoriteButton(isFavorite: currentItem.isFavorite) {
                        store.toggleFavorite(for: item.id)
                    }

                    if currentItem.supportsSharing {
                        PreviewHeaderShareButton(item: currentItem)
                    }
                    PreviewHeaderActionBar(actions: headerActions)
                }
            }

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(size: currentItem.isCode ? 13 : 14, weight: .regular, design: currentItem.isCode ? .monospaced : .default))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.accentColor.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
