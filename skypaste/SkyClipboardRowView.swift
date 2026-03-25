import AppKit
import SwiftUI

struct ClipboardRowView: View {
    enum Style {
        case popover
        case panel
    }

    let item: ClipboardItem
    let timeText: String
    var isSelected: Bool = false
    var style: Style = .panel
    var iconSize: CGFloat = 40
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

                Text("\(item.subtitle) • \(timeText)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
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
        .onChange(of: item.id) { _, _ in
            loadedPreview = nil
            loadPreviewIfNeeded()
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(style == .popover ? 0.11 : 0.10))
        } else if isHovered {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(style == .popover ? 0.52 : 0.42))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var previewThumbnail: some View {
        Group {
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
            return Color.accentColor.opacity(style == .popover ? 0.18 : 0.16)
        }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }

    private func loadPreviewIfNeeded() {
        guard loadedPreview == nil, let data = item.previewImageData else { return }
        loadedPreview = NSImage(data: data)
    }
}
