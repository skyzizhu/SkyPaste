import AppKit
import SwiftUI

@MainActor
final class PasteboardDebugModel: ObservableObject {
    @Published var changeCount: Int = 0
    @Published var rawTypes: [String] = []
    @Published var decodedSummary: String = L10n.tr("debug.no_data")
    @Published var preview: String = ""

    func refresh() {
        let pasteboard = NSPasteboard.general
        changeCount = pasteboard.changeCount

        let items = pasteboard.pasteboardItems ?? []
        rawTypes = items.enumerated().flatMap { index, item in
            item.types.map { "item[\(index)] • \($0.rawValue)" }
        }

        switch ClipboardDecoder.decode(from: pasteboard) {
        case .none:
            decodedSummary = L10n.tr("debug.none")
            preview = ""

        case .item(let item):
            switch item.content {
            case .text(let value):
                decodedSummary = L10n.tr("debug.text")
                preview = value

            case .image(let data, let name, let originalByteCount, let previewOnly):
                decodedSummary = L10n.tr("debug.image")
                let namePart: String
                if let name, !name.isEmpty {
                    namePart = L10n.format("debug.name_prefix", name)
                } else {
                    namePart = ""
                }
                let currentKB = max(1, data.count / 1024)
                let originalKB = max(1, originalByteCount / 1024)
                preview = previewOnly ? "\(namePart)\(currentKB) KB preview / \(originalKB) KB original" : "\(namePart)\(originalKB) KB"

            case .fileURLs(let urls):
                decodedSummary = L10n.tr("debug.file_urls")
                preview = urls.map(\.path).joined(separator: "\n")
            }
        }
    }
}

struct PasteboardDebugPanelView: View {
    @StateObject private var model = PasteboardDebugModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("debug.title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L10n.tr("debug.refresh")) {
                    model.refresh()
                }
            }

            Text(L10n.format("debug.change_count", model.changeCount))
                .font(.system(size: 12, design: .monospaced))

            Text(L10n.format("debug.decoded", model.decodedSummary))
                .font(.system(size: 12, design: .monospaced))

            Text(L10n.tr("debug.raw_types"))
                .font(.system(size: 12, weight: .medium))

            List(model.rawTypes, id: \.self) { type in
                Text(type)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
            }
            .frame(minHeight: 180)

            Text(L10n.tr("debug.preview"))
                .font(.system(size: 12, weight: .medium))

            ScrollView {
                Text(model.preview.isEmpty ? L10n.tr("debug.empty") : model.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120)
        }
        .padding(12)
        .frame(width: 620, height: 560)
        .onAppear {
            model.refresh()
        }
    }
}
