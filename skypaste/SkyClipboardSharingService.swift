import AppKit
import Foundation

enum ClipboardSharingService {
    static func presentPicker(for item: ClipboardItem, relativeTo anchorView: NSView? = nil) {
        let items = sharingItems(for: item)
        guard !items.isEmpty else { return }
        guard let view = anchorView ?? NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }

        let picker = NSSharingServicePicker(items: items)
        let rect = anchorView == nil
            ? view.bounds
            : NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: anchorView == nil ? .minY : .maxY)
    }

    static func sharingItems(for item: ClipboardItem) -> [Any] {
        switch item.content {
        case .text(let value):
            if item.isURL, let url = item.browserURL {
                return [url]
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]

        case .image(let data, _, _, _):
            if let image = NSImage(data: data) {
                return [image]
            }
            return data.isEmpty ? [] : [data]

        case .fileURLs(let urls, _):
            return urls
        }
    }
}
