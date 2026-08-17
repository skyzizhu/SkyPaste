import AppKit
import SwiftUI

struct TextPreviewView: View {
    let item: ClipboardItem
    let text: String
    let onCopy: () -> Void
    let onOpenURL: (() -> Void)?
    let onOpenEmail: (() -> Void)?

    private var headerActions: [PreviewHeaderAction] {
        var actions = [
            PreviewHeaderAction(
                title: item.isURL ? L10n.tr("menu.copy_link") : L10n.tr("menu.copy"),
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("preview.text_title"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    if item.supportsSharing {
                        PreviewHeaderShareButton(item: item)
                    }
                    PreviewHeaderActionBar(actions: headerActions)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(size: item.isCode ? 13 : 14, weight: .regular, design: item.isCode ? .monospaced : .default))
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
