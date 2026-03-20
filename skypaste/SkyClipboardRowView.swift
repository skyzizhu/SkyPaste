import AppKit
import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardItem
    let timeText: String
    var isSelected: Bool = false
    var iconSize: CGFloat = 40
    @State private var loadedPreview: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            if item.isImage {
                previewThumbnail
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: item.isCode ? 11.5 : 12, weight: .medium, design: item.isCode ? .monospaced : .default))
                    .lineLimit(item.isCode ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: item.isCode)

                Text("\(item.subtitle) • \(timeText)")
                    .font(.system(size: 10))
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
        .padding(.horizontal, 1)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
                }
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
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func loadPreviewIfNeeded() {
        guard loadedPreview == nil, let data = item.previewImageData else { return }
        loadedPreview = NSImage(data: data)
    }
}
