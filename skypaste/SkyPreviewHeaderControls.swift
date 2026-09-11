import AppKit
import SwiftUI

struct PreviewHeaderAction: Identifiable {
    let title: String
    let systemImage: String
    let action: () -> Void

    var id: String { "\(systemImage)|\(title)" }
}

@MainActor
final class GlobalToastModel: ObservableObject {
    @Published var message: String = ""
}

struct GlobalToastView: View {
    @ObservedObject var model: GlobalToastModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)

            Text(model.message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .fixedSize()
        .background(backgroundColor)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.94) : Color.black.opacity(0.86)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.84) : Color.white.opacity(0.96)
    }

    private var iconColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.72) : Color.white.opacity(0.92)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }
}

struct PreviewHeaderActionBar: View {
    let actions: [PreviewHeaderAction]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    Label(action.title, systemImage: action.systemImage)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                }
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct PreviewHeaderView<ActionContent: View>: View {
    let title: String
    let secondaryText: String?
    let item: ClipboardItem
    @ViewBuilder let actions: () -> ActionContent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                itemIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    if let secondaryText, !secondaryText.isEmpty {
                        Text(secondaryText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    PreviewSourceInfoView(item: item)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    actions()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollClipDisabled()
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .background(headerBackground)
    }

    @ViewBuilder
    private var itemIcon: some View {
        Image(systemName: headerIconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
            }
    }

    private var headerIconName: String {
        if item.isEmail { return "envelope.fill" }
        if item.isURL { return "link" }
        if item.isCode { return "chevron.left.forwardslash.chevron.right" }
        if item.isImage { return "photo.fill" }
        if item.singleFileSystemItemKind == .folder { return "folder.fill" }
        if item.isFileCollection { return "doc.fill" }
        return "text.alignleft"
    }

    private var headerBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color(nsColor: .controlBackgroundColor).opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.72)
        }
    }
}

struct PreviewHeaderShareButton: View {
    let item: ClipboardItem

    var body: some View {
        Button {
            ClipboardSharingService.presentPicker(for: item)
        } label: {
            Label(L10n.tr("menu.share"), systemImage: "square.and.arrow.up")
                .lineLimit(1)
                .padding(.horizontal, 3)
        }
        .fixedSize()
    }
}

struct PreviewHeaderSaveAsButton: View {
    let item: ClipboardItem
    let onSaveAs: () -> Void

    var body: some View {
        if item.supportsSaveAs {
            Button(action: onSaveAs) {
                Label(L10n.tr("menu.save_as"), systemImage: "square.and.arrow.down")
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
            .fixedSize()
        }
    }
}

struct PreviewHeaderFavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isFavorite ? L10n.tr("menu.unfavorite") : L10n.tr("menu.favorite"),
                systemImage: isFavorite ? "star.slash" : "star"
            )
            .lineLimit(1)
            .padding(.horizontal, 3)
        }
        .fixedSize()
    }
}

struct PreviewSourceInfoView: View {
    let item: ClipboardItem
    @State private var sourceAppIcon: NSImage?
    @State private var sourceAppIconRequestKey: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(L10n.tr("preview.source_label"))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            sourceIcon

            Text(sourceName)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(sourceHelpText)
        .onAppear {
            loadSourceAppIconIfNeeded()
        }
        .onChange(of: item.sourceApp?.bundleID) {
            sourceAppIcon = nil
            sourceAppIconRequestKey = nil
            loadSourceAppIconIfNeeded()
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let sourceAppIcon {
            Image(nsImage: sourceAppIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: sourceSystemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    private var sourceName: String {
        if let sourceApp = item.sourceApp {
            return L10n.format("preview.source_app", sourceApp.name)
        }

        if let badgeText = item.source.badgeText {
            return L10n.format("preview.source_device", badgeText)
        }

        return L10n.tr("preview.source_local")
    }

    private var sourceHelpText: String {
        "\(L10n.tr("preview.source_label")) \(sourceName)"
    }

    private var sourceSystemImage: String {
        if let systemName = item.source.deviceIconSystemName {
            return systemName
        }
        return item.sourceApp == nil ? "macbook" : "app"
    }

    private func loadSourceAppIconIfNeeded() {
        guard sourceAppIcon == nil, let sourceApp = item.sourceApp else { return }
        let requestKey = sourceApp.bundleID
        sourceAppIconRequestKey = requestKey
        ClipboardSourceAppIconProvider.shared.loadIcon(for: sourceApp) { icon in
            guard sourceAppIconRequestKey == requestKey else { return }
            sourceAppIcon = icon
        }
    }
}
