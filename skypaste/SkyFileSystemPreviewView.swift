import AppKit
import SwiftUI

@MainActor
final class FileSystemPreviewModel: ObservableObject {
    enum State {
        case loading
        case loaded(FileSystemPreviewSnapshot)
    }

    @Published private(set) var state: State = .loading
    private let item: ClipboardItem

    init(item: ClipboardItem) {
        self.item = item
        load()
    }

    private func load() {
        let item = item
        Task.detached(priority: .userInitiated) {
            let snapshot = FileSystemPreviewSnapshot.build(for: item)
            await MainActor.run {
                self.state = .loaded(snapshot)
            }
        }
    }
}

struct FileSystemPreviewSnapshot: Equatable {
    let representedURLs: [URL]
    let availableURLs: [URL]
    let missingURLs: [URL]
    let displayName: String
    let kind: ClipboardFileSystemItemKind?
    let typeDescription: String
    let sizeBytes: Int64?
    let sizeText: String
    let pathText: String
    let fileExtensionText: String?
    let modifiedAtText: String?
    let itemCount: Int?
    let directFileCount: Int?
    let directFolderCount: Int?
    let directoryEntries: [FileSystemPreviewDirectoryEntry]

    var isMissing: Bool {
        availableURLs.isEmpty
    }

    var shouldShowContents: Bool {
        !directoryEntries.isEmpty || kind == .folder || representedURLs.count > 1
    }

    static func build(for item: ClipboardItem) -> FileSystemPreviewSnapshot {
        let urls = item.fileURLs ?? []
        let fileManager = FileManager.default
        let availableURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        let missingURLs = urls.filter { !fileManager.fileExists(atPath: $0.path) }

        if let singleURL = urls.first, urls.count == 1 {
            let kind = item.singleFileSystemItemKind ?? fileSystemKind(for: singleURL)
            let displayName = singleURL.lastPathComponent
            let typeDescription = typeDescription(for: singleURL, fallbackKind: kind)
            let pathText = singleURL.path

            switch kind {
            case .folder:
                let entries = availableURLs.isEmpty ? [] : immediateEntries(in: singleURL)
                let sizeBytes = availableURLs.isEmpty ? nil : recursiveSize(of: singleURL)
                return FileSystemPreviewSnapshot(
                    representedURLs: urls,
                    availableURLs: availableURLs,
                    missingURLs: missingURLs,
                    displayName: displayName,
                    kind: .folder,
                    typeDescription: typeDescription,
                    sizeBytes: sizeBytes,
                    sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
                    pathText: pathText,
                    fileExtensionText: nil,
                    modifiedAtText: nil,
                    itemCount: availableURLs.isEmpty ? nil : entries.count,
                    directFileCount: availableURLs.isEmpty ? nil : entries.filter { $0.kind == .file }.count,
                    directFolderCount: availableURLs.isEmpty ? nil : entries.filter { $0.kind == .folder }.count,
                    directoryEntries: entries
                )
            case .file:
                let sizeBytes = availableURLs.isEmpty ? nil : fileSize(of: singleURL)
                return FileSystemPreviewSnapshot(
                    representedURLs: urls,
                    availableURLs: availableURLs,
                    missingURLs: missingURLs,
                    displayName: displayName,
                    kind: .file,
                    typeDescription: typeDescription,
                    sizeBytes: sizeBytes,
                    sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
                    pathText: pathText,
                    fileExtensionText: fileExtensionText(for: singleURL),
                    modifiedAtText: availableURLs.isEmpty ? nil : modifiedDateText(for: singleURL),
                    itemCount: nil,
                    directFileCount: nil,
                    directFolderCount: nil,
                    directoryEntries: []
                )
            }
        }

        let representedKinds = urls.map(fileSystemKind(for:))
        let distinctKinds = Set(representedKinds.map { $0 == .folder ? "folder" : "file" })
        let kind: ClipboardFileSystemItemKind? = distinctKinds.count == 1 ? representedKinds.first : nil
        let sizeBytes = availableURLs.isEmpty ? nil : availableURLs.reduce(Int64(0)) { partial, url in
            partial + totalSize(of: url)
        }

        return FileSystemPreviewSnapshot(
            representedURLs: urls,
            availableURLs: availableURLs,
            missingURLs: missingURLs,
            displayName: item.title,
            kind: kind,
            typeDescription: kind.map { $0 == .folder ? L10n.tr("preview.file_system_type_folder") : L10n.tr("preview.file_system_type_file") } ?? L10n.tr("preview.file_system_type_mixed"),
            sizeBytes: sizeBytes,
            sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
            pathText: L10n.tr("preview.file_system_multiple_locations"),
            fileExtensionText: nil,
            modifiedAtText: nil,
            itemCount: urls.count,
            directFileCount: nil,
            directFolderCount: nil,
            directoryEntries: urls.map(selectionEntry(for:))
        )
    }

    private static func selectionEntry(for url: URL) -> FileSystemPreviewDirectoryEntry {
        let kind = fileSystemKind(for: url)
        return FileSystemPreviewDirectoryEntry(
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            detailText: kind == .folder ? L10n.tr("preview.file_system_type_folder") : typeDescription(for: url, fallbackKind: .file),
            sizeText: kind == .folder ? nil : fileSize(of: url).map(formatByteCount)
        )
    }

    private static func immediateEntries(in directoryURL: URL) -> [FileSystemPreviewDirectoryEntry] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        let childURLs = withSecurityScopedAccess(to: directoryURL) {
            try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        }
        guard let childURLs else {
            return []
        }

        return childURLs
            .sorted { lhs, rhs in
                let lhsKind = fileSystemKind(for: lhs)
                let rhsKind = fileSystemKind(for: rhs)
                if lhsKind != rhsKind {
                    return lhsKind == .folder
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let kind = fileSystemKind(for: url)
                return FileSystemPreviewDirectoryEntry(
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    detailText: typeDescription(for: url, fallbackKind: kind),
                    sizeText: kind == .folder ? nil : fileSize(of: url).map(formatByteCount)
                )
            }
    }

    private static func totalSize(of url: URL) -> Int64 {
        switch fileSystemKind(for: url) {
        case .file:
            return fileSize(of: url) ?? 0
        case .folder:
            return recursiveSize(of: url) ?? 0
        }
    }

    private static func fileSize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
        let values = withSecurityScopedAccess(to: url) {
            try? url.resourceValues(forKeys: keys)
        }
        guard let values else { return nil }
        if let value = values.totalFileSize { return Int64(value) }
        if let value = values.fileSize { return Int64(value) }
        if let value = values.totalFileAllocatedSize { return Int64(value) }
        if let value = values.fileAllocatedSize { return Int64(value) }
        return nil
    }

    private static func recursiveSize(of directoryURL: URL) -> Int64? {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
        return withSecurityScopedAccess(to: directoryURL) {
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                return nil
            }

            var total: Int64 = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    continue
                }
                if let value = values?.totalFileSize {
                    total += Int64(value)
                } else if let value = values?.fileSize {
                    total += Int64(value)
                } else if let value = values?.totalFileAllocatedSize {
                    total += Int64(value)
                } else if let value = values?.fileAllocatedSize {
                    total += Int64(value)
                }
            }

            return total
        }
    }

    private static func fileExtensionText(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return L10n.tr("preview.file_system_unavailable") }
        return ext.uppercased()
    }

    private static func modifiedDateText(for url: URL) -> String? {
        let values = withSecurityScopedAccess(to: url) {
            try? url.resourceValues(forKeys: [.contentModificationDateKey])
        }
        guard let date = values?.contentModificationDate else { return nil }
        return L10n.dateTimeText(date)
    }

    private static func typeDescription(for url: URL, fallbackKind: ClipboardFileSystemItemKind?) -> String {
        if fallbackKind == .folder {
            return L10n.tr("preview.file_system_type_folder")
        }

        if let values = withSecurityScopedAccess(to: url, {
            try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
        }),
           let localizedTypeDescription = values.localizedTypeDescription,
           !localizedTypeDescription.isEmpty {
            return localizedTypeDescription
        }

        switch fallbackKind {
        case .folder:
            return L10n.tr("preview.file_system_type_folder")
        case .file:
            return L10n.tr("preview.file_system_type_file")
        case nil:
            return L10n.tr("preview.file_system_type_mixed")
        }
    }

    private static func fileSystemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = withSecurityScopedAccess(to: url, {
            try? url.resourceValues(forKeys: [.isDirectoryKey])
        }), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }

    private static func formatByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func withSecurityScopedAccess<T>(to url: URL, _ work: () -> T) -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return work()
    }
}

struct FileSystemPreviewDirectoryEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let kind: ClipboardFileSystemItemKind
    let detailText: String
    let sizeText: String?

    var id: String { url.path }
}

struct FileSystemPreviewView: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onOpen: () -> Void
    let onRevealInFinder: (() -> Void)?
    @StateObject private var model: FileSystemPreviewModel

    private var headerActions: [PreviewHeaderAction] {
        var actions = [
            PreviewHeaderAction(
                title: L10n.tr("menu.copy"),
                systemImage: "doc.on.doc",
                action: onCopy
            ),
            PreviewHeaderAction(
                title: L10n.tr("menu.copy_path"),
                systemImage: "text.alignleft",
                action: onCopyPath
            )
        ]

        if let onRevealInFinder {
            actions.append(
                PreviewHeaderAction(
                    title: L10n.tr("menu.reveal_in_finder"),
                    systemImage: "folder.badge.gearshape",
                    action: onRevealInFinder
                )
            )
        }

        actions.append(
            PreviewHeaderAction(
                title: item.openActionTitle,
                systemImage: item.singleFileSystemItemKind == .folder ? "folder" : "arrow.up.right.square",
                action: onOpen
            )
        )

        return actions
    }

    init(
        item: ClipboardItem,
        onCopy: @escaping () -> Void,
        onCopyPath: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onRevealInFinder: (() -> Void)? = nil
    ) {
        self.item = item
        self.onCopy = onCopy
        self.onCopyPath = onCopyPath
        self.onOpen = onOpen
        self.onRevealInFinder = onRevealInFinder
        _model = StateObject(wrappedValue: FileSystemPreviewModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch model.state {
                case .loading:
                    loadingView
                case .loaded(let snapshot):
                    contentView(for: snapshot)
                }
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
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("preview.file_system_title"))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(headerTitleText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 8) {
                if item.supportsSharing {
                    PreviewHeaderShareButton(item: item)
                }
                PreviewHeaderActionBar(actions: headerActions)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var headerTitleText: String {
        guard item.singleFileSystemItemKind == .folder,
              let folderURL = item.fileURLs?.first,
              item.fileURLs?.count == 1 else {
            return item.title
        }

        return folderURL.lastPathComponent
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.tr("preview.file_system_loading"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contentView(for snapshot: FileSystemPreviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !snapshot.missingURLs.isEmpty {
                    missingItemsBanner(snapshot.missingURLs)
                }

                infoSection(snapshot)

                if snapshot.shouldShowContents {
                    contentsSection(snapshot)
                }
            }
            .padding(24)
        }
    }

    private func missingItemsBanner(_ missingURLs: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("preview.file_system_not_found"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)

            Text(L10n.tr("preview.file_system_not_found_message"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ForEach(missingURLs, id: \.path) { url in
                Text(url.path)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private func infoSection(_ snapshot: FileSystemPreviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("preview.file_system_section_info"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            VStack(spacing: 12) {
                infoRow(label: L10n.tr("preview.file_system_label_name"), value: snapshot.displayName)
                infoRow(label: L10n.tr("preview.file_system_label_type"), value: snapshot.typeDescription)
                if let fileExtensionText = snapshot.fileExtensionText {
                    infoRow(label: L10n.tr("preview.file_system_label_extension"), value: fileExtensionText)
                }
                infoRow(label: L10n.tr("preview.file_system_label_size"), value: snapshot.sizeText)
                if let modifiedAtText = snapshot.modifiedAtText {
                    infoRow(label: L10n.tr("preview.file_system_label_modified"), value: modifiedAtText)
                }
                infoRow(label: L10n.tr("preview.file_system_label_path"), value: snapshot.pathText, monospaced: true)
                if let itemCount = snapshot.itemCount {
                    infoRow(label: L10n.tr("preview.file_system_label_items"), value: L10n.format("preview.file_system_item_count", itemCount))
                }
                if let directFileCount = snapshot.directFileCount {
                    infoRow(label: L10n.tr("preview.file_system_label_files"), value: L10n.format("preview.file_system_file_count", directFileCount))
                }
                if let directFolderCount = snapshot.directFolderCount {
                    infoRow(label: L10n.tr("preview.file_system_label_folders"), value: L10n.format("preview.file_system_folder_count", directFolderCount))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func infoRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentsSection(_ snapshot: FileSystemPreviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("preview.file_system_section_contents"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            if snapshot.directoryEntries.isEmpty {
                Text(L10n.tr("preview.file_system_empty_directory"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.directoryEntries.enumerated()), id: \.element.id) { index, entry in
                        FileSystemPreviewEntryRow(entry: entry)

                        if index < snapshot.directoryEntries.count - 1 {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct FileSystemPreviewEntryRow: View {
    let entry: FileSystemPreviewDirectoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBackgroundColor)

                Image(systemName: entry.kind == .folder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconForegroundColor)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(entry.detailText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let sizeText = entry.sizeText {
                Text(sizeText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
    }

    private var iconBackgroundColor: Color {
        entry.kind == .folder ? Color.orange.opacity(0.16) : Color.indigo.opacity(0.14)
    }

    private var iconForegroundColor: Color {
        entry.kind == .folder ? Color.orange.opacity(0.9) : Color.indigo.opacity(0.9)
    }
}
