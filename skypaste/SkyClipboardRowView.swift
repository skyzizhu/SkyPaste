import AppKit
import SwiftUI

struct ClipboardRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Style {
        case popover
        case panel
    }

    let item: ClipboardItem
    let timeText: String
    var isSelected: Bool = false
    var style: Style = .panel
    var iconSize: CGFloat = 40
    var onPreview: (() -> Void)? = nil
    @State private var loadedPreview: NSImage?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if item.isImage {
                previewThumbnail
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: item.isCode ? 12 : 13, weight: .semibold, design: item.isCode ? .monospaced : .default))
                    .lineLimit(item.isCode ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: item.isCode)

                HStack(spacing: 6) {
                    Text(metadataText)
                        .lineLimit(1)

                    if let deviceIcon = item.source.deviceIconSystemName {
                        Image(systemName: deviceIcon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.9))
                            .help(item.source.badgeText ?? "")
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(.trailing, showSelectionCopyHint ? copyHintReservedWidth : 0)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if showSelectionCopyHint {
                selectionCopyHint
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            loadPreviewIfNeeded()
        }
        .onDisappear {
            loadedPreview = nil
        }
        .onChange(of: item.id) {
            loadedPreview = nil
            loadPreviewIfNeeded()
        }
    }

    private var showSelectionCopyHint: Bool {
        isSelected
    }

    private var copyHintReservedWidth: CGFloat {
        style == .popover ? 86 : 80
    }

    private var selectionCopyHint: some View {
        Text(L10n.tr("menu.command_v_copy"))
            .font(.system(size: 8.5, weight: .regular, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.76) : Color.primary.opacity(0.55))
            .lineLimit(1)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? (style == .popover ? 0.22 : 0.18) : (style == .popover ? 0.11 : 0.10)))
        } else if isHovered {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(style == .popover ? 0.10 : 0.08) : Color.white.opacity(style == .popover ? 0.52 : 0.42))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var previewThumbnail: some View {
        let thumbnail = Group {
            if let loadedPreview {
                Image(nsImage: loadedPreview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }

        if let onPreview {
            Button(action: onPreview) {
                thumbnail
            }
            .buttonStyle(.plain)
            .help(L10n.tr("preview.open"))
        } else {
            thumbnail
        }
    }

    private var cornerRadius: CGFloat {
        style == .popover ? 12 : 8
    }

    private var horizontalPadding: CGFloat {
        style == .popover ? 10 : 1
    }

    private var verticalPadding: CGFloat {
        style == .popover ? 9 : 6
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.32 : (style == .popover ? 0.18 : 0.16))
        }
        return isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05) : .clear
    }

    private var metadataText: String {
        [item.subtitle, timeText].joined(separator: " • ")
    }

    private func loadPreviewIfNeeded() {
        guard loadedPreview == nil, let data = item.previewImageData else { return }
        loadedPreview = NSImage(data: data)
    }
}
