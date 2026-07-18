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
    var showsSelectionIndicator: Bool = false
    var style: Style = .panel
    var iconSize: CGFloat = 40
    var onPrimaryMouseDown: (() -> Void)? = nil
    var onSecondaryMouseDown: (() -> Void)? = nil
    var onAnchorViewChange: ((NSView?) -> Void)? = nil
    var onPreview: (() -> Void)? = nil
    var onPreviewDoubleTap: (() -> Void)? = nil
    @State private var loadedPreview: NSImage?
    @State private var sourceBadgeIcon: NSImage?
    @State private var previewRequestKey: String?
    @State private var sourceBadgeRequestKey: String?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if showsImageThumbnail {
                previewThumbnail
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if !item.isImage {
                            titleTypeIcon
                        }

                        Text(item.title)
                            .font(.system(size: item.isCode ? 12 : 13, weight: .semibold, design: item.isCode ? .monospaced : .default))
                            .lineLimit(item.isCode ? 2 : 1)
                            .truncationMode(titleTruncationMode)
                            .fixedSize(horizontal: false, vertical: item.isCode)
                    }

                    HStack(spacing: 6) {
                        Text(metadataText)
                            .lineLimit(1)

                        sourceBadgeView
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingBadges
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .background(
            RowMouseDownObserver(
                onPrimaryMouseDown: onPrimaryMouseDown,
                onSecondaryMouseDown: onSecondaryMouseDown,
                onAnchorViewChange: onAnchorViewChange
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if showSelectionCopyHint {
                selectionCopyHint
                    .padding(.bottom, 4)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            loadPreviewIfNeeded()
            loadSourceBadgeIfNeeded()
        }
        .onDisappear {
            loadedPreview = nil
            previewRequestKey = nil
            sourceBadgeIcon = nil
            sourceBadgeRequestKey = nil
        }
        .onChange(of: item.id) {
            loadedPreview = nil
            previewRequestKey = nil
            loadPreviewIfNeeded()
            sourceBadgeIcon = nil
            sourceBadgeRequestKey = nil
            loadSourceBadgeIfNeeded()
        }
    }

    private var showSelectionCopyHint: Bool {
        isSelected
    }

    private var selectionCopyHint: some View {
        Text(L10n.tr("menu.command_v_copy"))
            .font(.system(size: 8.5, weight: .regular, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.76) : Color.primary.opacity(0.55))
            .lineLimit(1)
    }

    @ViewBuilder
    private var trailingBadges: some View {
        HStack(spacing: 6) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yellow)
                    .frame(width: 14, alignment: .center)
            }

            if showsSelectionIndicator {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? Color.accentColor
                            : Color.secondary.opacity(colorScheme == .dark ? 0.84 : 0.64)
                    )
                    .frame(width: 16, alignment: .center)
            }
        }
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
        .overlay(alignment: .bottomTrailing) {
            if item.isSingleImageFile {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    Image(systemName: "doc.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.indigo.opacity(0.92))
                }
                .frame(width: 16, height: 16)
                .padding(4)
            }
        }

        if let onPreview {
            Button(action: onPreview) {
                thumbnail
            }
            .buttonStyle(.plain)
            .help(L10n.tr("preview.open"))
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onPreviewDoubleTap?()
                    }
            )
        } else {
            thumbnail
        }
    }

    private var titleTypeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconBackgroundColor)

            Image(systemName: iconSystemName)
                .font(.system(size: titleIconSymbolSize, weight: .semibold))
                .foregroundStyle(iconForegroundColor)
        }
        .frame(width: titleIconSize, height: titleIconSize)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            return Color.accentColor.opacity(colorScheme == .dark ? 0.32 : (style == .popover ? 0.18 : 0.16))
        }
        return isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05) : .clear
    }

    private var metadataText: String {
        [item.subtitle, timeText].joined(separator: " • ")
    }

    private var titleTruncationMode: Text.TruncationMode {
        if item.singleFileSystemItemKind == .file || item.singleFileSystemItemKind == .folder {
            return .middle
        }
        return .tail
    }

    @ViewBuilder
    private var sourceBadgeView: some View {
        if let sourceApp = item.sourceApp {
            Group {
                if let sourceBadgeIcon {
                    Image(nsImage: sourceBadgeIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: "app.badge")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                }
            }
            .help(sourceApp.name)
        } else if let deviceIcon = item.source.deviceIconSystemName {
            Image(systemName: deviceIcon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.9))
                .help(item.source.badgeText ?? "")
        }
    }

    private var iconSystemName: String {
        if item.isEmail {
            return "envelope.fill"
        }
        if item.isURL {
            return "link"
        }
        if item.isCode {
            return "chevron.left.forwardslash.chevron.right"
        }
        if item.isFileCollection {
            if item.singleFileSystemItemKind == .folder {
                return "folder.fill"
            }
            return item.fileURLs?.count ?? 0 > 1 ? "doc.on.doc.fill" : "doc.fill"
        }
        return "text.alignleft"
    }

    private var iconBackgroundColor: Color {
        switch iconPalette {
        case .text:
            return Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .email:
            return Color.blue.opacity(colorScheme == .dark ? 0.23 : 0.13)
        case .url:
            return Color.cyan.opacity(colorScheme == .dark ? 0.24 : 0.16)
        case .code:
            return Color.teal.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .file:
            return Color.indigo.opacity(colorScheme == .dark ? 0.24 : 0.14)
        case .folder:
            return Color.orange.opacity(colorScheme == .dark ? 0.24 : 0.16)
        }
    }

    private var iconForegroundColor: Color {
        switch iconPalette {
        case .text:
            return Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.72)
        case .email:
            return Color.blue.opacity(colorScheme == .dark ? 0.94 : 0.86)
        case .url:
            return Color.cyan.opacity(colorScheme == .dark ? 0.96 : 0.9)
        case .code:
            return Color.teal.opacity(colorScheme == .dark ? 0.96 : 0.9)
        case .file:
            return Color.indigo.opacity(colorScheme == .dark ? 0.95 : 0.9)
        case .folder:
            return Color.orange.opacity(colorScheme == .dark ? 0.96 : 0.9)
        }
    }

    private enum TypeIconPalette {
        case text
        case email
        case url
        case code
        case file
        case folder
    }

    private var iconPalette: TypeIconPalette {
        if item.isEmail {
            return .email
        }
        if item.isURL {
            return .url
        }
        if item.isCode {
            return .code
        }
        if item.isFileCollection {
            return item.singleFileSystemItemKind == .folder ? .folder : .file
        }
        return .text
    }

    private var titleIconSize: CGFloat {
        item.isCode ? 18 : 16
    }

    private var titleIconSymbolSize: CGFloat {
        switch iconSystemName {
        case "chevron.left.forwardslash.chevron.right":
            return 9.5
        case "doc.on.doc.fill":
            return 9
        default:
            return 8.5
        }
    }

    private func loadPreviewIfNeeded() {
        guard loadedPreview == nil else { return }
        if let data = item.previewImageData {
            let requestKey = "\(item.id.uuidString)#image-data"
            previewRequestKey = requestKey
            ClipboardPreviewImageProvider.shared.loadThumbnail(from: data, cacheKey: requestKey) { image in
                guard previewRequestKey == requestKey else { return }
                loadedPreview = image
            }
            return
        }
        if item.isSingleImageFile, let url = item.singleFileURL {
            let requestKey = url.path
            previewRequestKey = requestKey
            ClipboardPreviewImageProvider.shared.loadThumbnail(at: url, maxPixelSize: 160) { image in
                guard previewRequestKey == requestKey else { return }
                loadedPreview = image
            }
        }
    }

    private func loadSourceBadgeIfNeeded() {
        guard sourceBadgeIcon == nil, let sourceApp = item.sourceApp else { return }
        let requestKey = sourceApp.bundleID
        sourceBadgeRequestKey = requestKey
        ClipboardSourceAppIconProvider.shared.loadIcon(for: sourceApp) { icon in
            guard sourceBadgeRequestKey == requestKey else { return }
            sourceBadgeIcon = icon
        }
    }

    private var showsImageThumbnail: Bool {
        item.isImage || item.isSingleImageFile
    }
}

final class ClipboardRowAnchor {
    weak var view: NSView?

    init(_ view: NSView?) {
        self.view = view
    }
}

private struct RowMouseDownObserver: NSViewRepresentable {
    let onPrimaryMouseDown: (() -> Void)?
    let onSecondaryMouseDown: (() -> Void)?
    let onAnchorViewChange: ((NSView?) -> Void)?

    func makeNSView(context: Context) -> RowMouseDownObserverView {
        let view = RowMouseDownObserverView()
        view.onPrimaryMouseDown = onPrimaryMouseDown
        view.onSecondaryMouseDown = onSecondaryMouseDown
        view.onAnchorViewChange = onAnchorViewChange
        return view
    }

    func updateNSView(_ nsView: RowMouseDownObserverView, context: Context) {
        nsView.onPrimaryMouseDown = onPrimaryMouseDown
        nsView.onSecondaryMouseDown = onSecondaryMouseDown
        nsView.onAnchorViewChange = onAnchorViewChange
    }
}

private final class RowMouseDownObserverView: NSView {
    var onPrimaryMouseDown: (() -> Void)?
    var onSecondaryMouseDown: (() -> Void)?
    var onAnchorViewChange: ((NSView?) -> Void)?
    private var isRegisteredForEvents = false

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            unregisterForEvents()
            onAnchorViewChange?(nil)
        } else {
            onAnchorViewChange?(self)
            registerForEventsIfNeeded()
        }
    }

    deinit {
        onAnchorViewChange?(nil)
        unregisterForEvents()
    }

    fileprivate func handleMouseDownEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            onPrimaryMouseDown?()
        case .rightMouseDown:
            onSecondaryMouseDown?()
        default:
            break
        }
    }

    private func registerForEventsIfNeeded() {
        guard !isRegisteredForEvents else { return }
        isRegisteredForEvents = true
        RowMouseDownEventCoordinator.shared.register(self)
    }

    private func unregisterForEvents() {
        guard isRegisteredForEvents else { return }
        isRegisteredForEvents = false
        RowMouseDownEventCoordinator.shared.unregister(self)
    }
}

private final class RowMouseDownEventCoordinator {
    static let shared = RowMouseDownEventCoordinator()

    private let registeredViews = NSHashTable<RowMouseDownObserverView>.weakObjects()
    private var eventMonitor: Any?

    private init() {}

    func register(_ view: RowMouseDownObserverView) {
        registeredViews.add(view)
        installMonitorIfNeeded()
    }

    func unregister(_ view: RowMouseDownObserverView) {
        registeredViews.remove(view)
        removeMonitorIfPossible()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dispatch(event)
            return event
        }
    }

    private func removeMonitorIfPossible() {
        guard registeredViews.allObjects.isEmpty, let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func dispatch(_ event: NSEvent) {
        guard let eventWindow = event.window else { return }

        for view in registeredViews.allObjects.reversed() {
            guard
                view.window === eventWindow,
                !view.isHiddenOrHasHiddenAncestor,
                view.alphaValue > 0.01
            else {
                continue
            }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { continue }
            view.handleMouseDownEvent(event)
            return
        }
    }
}
