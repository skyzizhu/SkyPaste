import AppKit
import SwiftUI

struct ImagePreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipboardStore
    let item: ClipboardItem
    let onCopy: (ClipboardItem) -> Void
    let onOpen: (ClipboardItem) -> Void
    let onSaveAs: (ClipboardItem) -> Void
    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnimationNonce = 0
    @State private var isAnnotating = false
    @State private var annotationColor: ImageAnnotationColor = .red
    @State private var annotationStrokeWidth = 4.0
    @State private var annotationStrokes: [ImageAnnotationStroke] = []
    @State private var annotationExportFailed = false
    @State private var annotatedPNG: Data?
    @State private var annotationRenderTask: Task<Data?, Never>?
    @State private var annotationExportID = UUID()

    private let image: NSImage?
    private let imagePixelSize: CGSize?

    init(
        store: ClipboardStore,
        item: ClipboardItem,
        onCopy: @escaping (ClipboardItem) -> Void,
        onOpen: @escaping (ClipboardItem) -> Void,
        onSaveAs: @escaping (ClipboardItem) -> Void
    ) {
        self.store = store
        self.item = item
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onSaveAs = onSaveAs
        let image = item.previewImage
        self.image = image
        if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            self.imagePixelSize = image?.size
        }
    }

    private var currentItem: ClipboardItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeaderView(
                title: L10n.tr("preview.title"),
                secondaryText: currentItem.subtitle,
                item: currentItem
            ) {
                HStack(spacing: 8) {
                    PreviewHeaderFavoriteButton(isFavorite: currentItem.isFavorite) {
                        store.toggleFavorite(for: item.id)
                    }

                    Button {
                        performImageAction(onCopy)
                    } label: {
                        Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
                    }

                    Button {
                        performImageAction(onOpen)
                    } label: {
                        Label(L10n.tr("preview.open_image"), systemImage: "arrow.up.forward.app")
                    }

                    PreviewHeaderSaveAsButton(item: currentItem) {
                        performImageAction(onSaveAs)
                    }

                    if currentItem.supportsSharing {
                        Button {
                            performImageAction { actionItem in
                                ClipboardSharingService.presentPicker(for: actionItem)
                            }
                        } label: {
                            Label(L10n.tr("menu.share"), systemImage: "square.and.arrow.up")
                        }
                    }

                    Button {
                        isAnnotating.toggle()
                    } label: {
                        Label(
                            L10n.tr(isAnnotating ? "preview.annotation_done" : "preview.annotate"),
                            systemImage: "pencil.tip"
                        )
                    }

                    Button {
                        updateZoomScale(clampedScale(zoomScale - 0.2), animated: true)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }

                    Button {
                        updateZoomScale(1, animated: true)
                    } label: {
                        Text(resetButtonTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(minWidth: 52)
                    }

                    Button {
                        updateZoomScale(clampedScale(zoomScale + 0.2), animated: true)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Divider()

            if isAnnotating {
                annotationToolbar
                Divider()
            }

            GeometryReader { proxy in
                ZStack {
                    if let image {
                        let viewport = previewSize(
                            for: image,
                            available: CGSize(width: proxy.size.width - 48, height: proxy.size.height - 48)
                        )
                        MagnifiableImagePreviewRepresentable(
                            image: image,
                            annotationStrokes: annotationStrokes,
                            isAnnotating: isAnnotating,
                            annotationColor: annotationColor,
                            annotationStrokeWidth: CGFloat(annotationStrokeWidth),
                            onStrokeCompleted: addAnnotationStroke,
                            onResolveDragItem: dragItem,
                            zoomScale: $zoomScale,
                            zoomAnimationNonce: zoomAnimationNonce,
                            availableSize: viewport
                        )
                        .frame(width: viewport.width, height: viewport.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
                    } else {
                        ContentUnavailableView(
                            L10n.tr("preview.unavailable"),
                            systemImage: "photo",
                            description: Text(L10n.tr("preview.unavailable_message"))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .bottomTrailing) {
                    if image != nil {
                        if isAnnotating {
                            annotationDoneButton
                                .padding(24)
                        } else {
                            dragHint
                                .padding(24)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .clipped()
                .background(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color.accentColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { annotationRenderTask?.cancel() }
        .alert(
            L10n.tr("preview.annotation_export_error_title"),
            isPresented: $annotationExportFailed
        ) {
            Button(L10n.tr("menu.ok"), role: .cancel) {}
        } message: {
            Text(L10n.tr("preview.annotation_export_error_message"))
        }
    }

    private var annotationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(L10n.tr("preview.annotation_hint"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(ImageAnnotationColor.allCases, id: \.self) { color in
                    Button {
                        annotationColor = color
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 17, height: 17)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(0.35), lineWidth: 0.8)
                            }
                            .padding(3)
                            .overlay {
                                Circle()
                                    .stroke(annotationColor == color ? Color.accentColor : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr(color.localizationKey))
                }

                HStack(spacing: 6) {
                    Image(systemName: "lineweight")
                        .foregroundStyle(.secondary)
                    Slider(value: $annotationStrokeWidth, in: 2...12, step: 1)
                        .frame(width: 104)
                        .accessibilityLabel(L10n.tr("preview.annotation_width"))
                    Text("\(Int(annotationStrokeWidth))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 18, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)

                Spacer()

                Button {
                    _ = annotationStrokes.popLast()
                    prepareAnnotationExport()
                } label: {
                    Label(L10n.tr("preview.annotation_undo"), systemImage: "arrow.uturn.backward")
                }
                .disabled(annotationStrokes.isEmpty)

                Button {
                    annotationStrokes.removeAll()
                    prepareAnnotationExport()
                } label: {
                    Label(L10n.tr("preview.annotation_clear"), systemImage: "trash")
                }
                .disabled(annotationStrokes.isEmpty)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 26)
        .padding(.vertical, 4)
    }

    private func addAnnotationStroke(_ stroke: ImageAnnotationStroke) {
        annotationStrokes.append(stroke)
        prepareAnnotationExport()
    }

    private func prepareAnnotationExport() {
        annotationRenderTask?.cancel()
        annotatedPNG = nil
        annotationExportID = UUID()
        guard !annotationStrokes.isEmpty, let sourceData = item.previewImageData else {
            annotationRenderTask = nil
            return
        }
        let strokes = annotationStrokes
        let task = Task.detached(priority: .userInitiated) {
            ImageAnnotationRenderer.pngData(for: sourceData, strokes: strokes)
        }
        annotationRenderTask = task
        Task {
            let data = await task.value
            if annotationStrokes == strokes {
                annotatedPNG = data
            }
        }
    }

    private func performImageAction(_ action: @escaping (ClipboardItem) -> Void) {
        guard !annotationStrokes.isEmpty else {
            action(currentItem)
            return
        }
        let strokes = annotationStrokes
        if let annotatedPNG {
            action(actionItem(with: annotatedPNG))
            return
        }
        guard let task = annotationRenderTask else {
            annotationExportFailed = true
            return
        }
        Task {
            guard let data = await task.value else {
                if annotationStrokes == strokes { annotationExportFailed = true }
                return
            }
            guard annotationStrokes == strokes else { return }
            annotatedPNG = data
            action(actionItem(with: data))
        }
    }

    private func dragItem() -> ClipboardItem? {
        guard !annotationStrokes.isEmpty else { return currentItem }
        guard let annotatedPNG else { return nil }
        return actionItem(with: annotatedPNG)
    }

    private func actionItem(with data: Data) -> ClipboardItem {
        let originalName: String?
        if case .image(_, let name, _, _) = currentItem.content {
            originalName = name
        } else {
            originalName = nil
        }
        let baseName = originalName.map { ($0 as NSString).deletingPathExtension } ?? "SkyPaste Image"
        return ClipboardItem(
            id: annotationExportID,
            createdAt: currentItem.createdAt,
            content: .image(data: data, name: "\(baseName).png", originalByteCount: data.count, previewOnly: false),
            fingerprint: annotationExportID.uuidString
        )
    }

    private func previewSize(for image: NSImage, available: CGSize) -> CGSize {
        let imageSize = imagePixelSize ?? image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: 240, height: 240) }
        let scale = min(max(available.width, 1) / imageSize.width, max(available.height, 1) / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.4), 5)
    }

    private var dragHint: some View {
        Label(
            L10n.tr(!annotationStrokes.isEmpty && annotatedPNG == nil
                ? "preview.annotation_preparing"
                : zoomScale > 1.01 ? "preview.drag_zoomed_hint" : "preview.drag_hint"),
            systemImage: "hand.point.up.left"
        )
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var annotationDoneButton: some View {
        Button {
            isAnnotating = false
        } label: {
            Label(L10n.tr("preview.annotation_done"), systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func updateZoomScale(_ value: CGFloat, animated: Bool) {
        let clamped = clampedScale(value)
        guard abs(zoomScale - clamped) > 0.001 else { return }
        zoomScale = clamped
        if animated {
            zoomAnimationNonce += 1
        }
    }

    private var resetButtonTitle: String {
        if abs(zoomScale - 1) < 0.01 {
            return L10n.tr("preview.fit")
        }
        return "\(Int(zoomScale * 100))%"
    }
}

private struct MagnifiableImagePreviewRepresentable: NSViewRepresentable {
    let image: NSImage
    let annotationStrokes: [ImageAnnotationStroke]
    let isAnnotating: Bool
    let annotationColor: ImageAnnotationColor
    let annotationStrokeWidth: CGFloat
    let onStrokeCompleted: (ImageAnnotationStroke) -> Void
    let onResolveDragItem: () -> ClipboardItem?
    @Binding var zoomScale: CGFloat
    let zoomAnimationNonce: Int
    let availableSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeNSView(context: Context) -> MagnifiableImageScrollView {
        let scrollView = MagnifiableImageScrollView()
        scrollView.onMagnificationChanged = { magnification in
            context.coordinator.updateZoomScale(magnification)
        }
        scrollView.onDoubleClickZoom = { magnification in
            context.coordinator.updateZoomScale(magnification)
        }
        return scrollView
    }

    func updateNSView(_ nsView: MagnifiableImageScrollView, context: Context) {
        nsView.onResolveDragItem = onResolveDragItem
        nsView.updateAnnotations(
            strokes: annotationStrokes,
            isEditing: isAnnotating,
            color: annotationColor,
            strokeWidth: annotationStrokeWidth,
            onStrokeCompleted: onStrokeCompleted
        )
        nsView.onMagnificationChanged = { magnification in
            context.coordinator.updateZoomScale(magnification)
        }
        nsView.onDoubleClickZoom = { magnification in
            context.coordinator.updateZoomScale(magnification)
        }
        nsView.update(
            image: image,
            zoomScale: zoomScale,
            animated: context.coordinator.consumeAnimationFlag(for: zoomAnimationNonce),
            availableSize: availableSize
        )
    }

    final class Coordinator {
        @Binding private var zoomScale: CGFloat
        private var lastAnimationNonce = 0

        init(zoomScale: Binding<CGFloat>) {
            _zoomScale = zoomScale
        }

        func updateZoomScale(_ magnification: CGFloat) {
            DispatchQueue.main.async {
                let clamped = min(max(magnification, 0.4), 5)
                if abs(self.zoomScale - clamped) > 0.001 {
                    self.zoomScale = clamped
                }
            }
        }

        func consumeAnimationFlag(for nonce: Int) -> Bool {
            guard nonce != lastAnimationNonce else { return false }
            lastAnimationNonce = nonce
            return true
        }
    }
}

private final class MagnifiableImageScrollView: NSScrollView {
    var onMagnificationChanged: ((CGFloat) -> Void)?
    var onDoubleClickZoom: ((CGFloat) -> Void)?
    var onResolveDragItem: (() -> ClipboardItem?)? {
        didSet { containerView.onResolveDragItem = onResolveDragItem }
    }

    private let containerView = PannableImageContainerView()
    private let imageView = NSImageView()
    private let annotationView = ImageAnnotationCanvasView()
    private var sourceImage: NSImage?
    private var sourceImageSize = CGSize(width: 240, height: 240)
    private var baseImageSize: CGSize = CGSize(width: 240, height: 240)
    private var currentScale: CGFloat = 1
    private var panStartOrigin: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(image: NSImage, zoomScale: CGFloat, animated: Bool, availableSize: CGSize) {
        if sourceImage !== image {
            sourceImage = image
            sourceImageSize = imageDisplaySize(for: image)
            imageView.image = image
        }
        baseImageSize = fittedImageSize(imageSize: sourceImageSize, availableSize: availableSize)
        let scaleChanged = abs(currentScale - zoomScale) > 0.001
        if scaleChanged {
            currentScale = zoomScale
        }
        applyLayout(animated: animated && scaleChanged)
    }

    func updateAnnotations(
        strokes: [ImageAnnotationStroke],
        isEditing: Bool,
        color: ImageAnnotationColor,
        strokeWidth: CGFloat,
        onStrokeCompleted: @escaping (ImageAnnotationStroke) -> Void
    ) {
        if annotationView.strokes != strokes {
            annotationView.strokes = strokes
        }
        if annotationView.isEditing != isEditing {
            annotationView.isEditing = isEditing
        }
        annotationView.color = color
        annotationView.strokeWidth = strokeWidth
        annotationView.onStrokeCompleted = onStrokeCompleted
        if containerView.isAnnotating != isEditing {
            containerView.isAnnotating = isEditing
        }
        updateCursor()
    }

    override func layout() {
        super.layout()
        applyLayout(animated: false)
    }

    override func magnify(with event: NSEvent) {
        currentScale = min(max(currentScale + event.magnification, 0.4), 5)
        onMagnificationChanged?(currentScale)
        applyLayout(animated: false)
    }

    private func configure() {
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        currentScale = 1

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(imageView)
        containerView.addSubview(annotationView)
        containerView.onPan = { [weak self] translation, state in
            self?.handlePan(translation: translation, state: state)
        }
        containerView.shouldPan = { [weak self] in
            self?.canPanContent == true
        }
        containerView.canBeginDrag = { [weak self] location in
            self?.imageView.frame.contains(location) == true
        }
        containerView.onDoubleClick = { [weak self] location in
            self?.handleDoubleClick(at: location)
        }
        documentView = containerView
    }

    private func applyLayout(animated: Bool) {
        let metrics = layoutMetrics()
        let targetBounds = CGRect(origin: .zero, size: metrics.containerSize)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                containerView.animator().frame = targetBounds
                imageView.animator().frame = metrics.imageFrame
                annotationView.animator().frame = metrics.imageFrame
                contentView.animator().setBoundsOrigin(metrics.targetOrigin)
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView)
                self.updateCursor()
            }
            return
        }

        containerView.frame = targetBounds
        imageView.frame = metrics.imageFrame
        annotationView.frame = metrics.imageFrame
        scroll(to: metrics.targetOrigin)
        updateCursor()
    }

    private func layoutMetrics() -> (containerSize: CGSize, imageFrame: CGRect, targetOrigin: CGPoint) {
        let scaledSize = CGSize(
            width: max(1, baseImageSize.width * currentScale),
            height: max(1, baseImageSize.height * currentScale)
        )
        let visibleSize = contentView.bounds.size
        let containerSize = CGSize(
            width: max(visibleSize.width, scaledSize.width),
            height: max(visibleSize.height, scaledSize.height)
        )
        let imageFrame = CGRect(
            x: max(0, (containerSize.width - scaledSize.width) / 2),
            y: max(0, (containerSize.height - scaledSize.height) / 2),
            width: scaledSize.width,
            height: scaledSize.height
        )
        let targetOrigin: CGPoint
        if currentScale <= 1.001 {
            targetOrigin = .zero
        } else {
            targetOrigin = clampedContentOrigin(contentView.bounds.origin)
        }
        return (containerSize, imageFrame, targetOrigin)
    }

    private func fittedImageSize(imageSize: CGSize, availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 240, height: 240)
        }

        let widthScale = availableSize.width / imageSize.width
        let heightScale = availableSize.height / imageSize.height
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private func imageDisplaySize(for image: NSImage) -> CGSize {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }

        if let representation = image.representations.first(where: {
            $0.pixelsWide > 0 && $0.pixelsHigh > 0
        }) {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }

        return image.size
    }

    private func handlePan(translation: CGPoint, state: NSGestureRecognizer.State) {
        guard canPanContent else { return }

        switch state {
        case .began:
            panStartOrigin = contentView.bounds.origin
        case .changed:
            let targetOrigin = CGPoint(
                x: panStartOrigin.x - translation.x,
                y: panStartOrigin.y - translation.y
            )
            scroll(to: clampedContentOrigin(targetOrigin))
        default:
            break
        }
    }

    private func handleDoubleClick(at location: CGPoint) {
        currentScale = currentScale > 1.01 ? 1 : 3
        onDoubleClickZoom?(currentScale)
        let metrics = layoutMetrics()
        let targetOrigin: CGPoint

        if currentScale > 1.01 {
            let visibleSize = contentView.bounds.size
            targetOrigin = clampedContentOrigin(
                CGPoint(
                    x: location.x - (visibleSize.width / 2),
                    y: location.y - (visibleSize.height / 2)
                )
            )
        } else {
            targetOrigin = .zero
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            containerView.animator().frame = CGRect(origin: .zero, size: metrics.containerSize)
            imageView.animator().frame = metrics.imageFrame
            annotationView.animator().frame = metrics.imageFrame
            contentView.animator().setBoundsOrigin(targetOrigin)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.reflectScrolledClipView(self.contentView)
            self.updateCursor()
        }
    }

    private func scroll(to origin: CGPoint) {
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func clampedContentOrigin(_ origin: CGPoint) -> CGPoint {
        let visibleSize = contentView.bounds.size
        let maxX = max(0, containerView.frame.width - visibleSize.width)
        let maxY = max(0, containerView.frame.height - visibleSize.height)
        return CGPoint(
            x: min(max(origin.x, 0), maxX),
            y: min(max(origin.y, 0), maxY)
        )
    }

    private var canPanContent: Bool {
        let visibleSize = contentView.bounds.size
        return containerView.frame.width > visibleSize.width + 1 ||
            containerView.frame.height > visibleSize.height + 1
    }

    private func updateCursor() {
        if annotationView.isEditing {
            containerView.cursor = .arrow
        } else if canPanContent {
            containerView.cursor = .openHand
        } else {
            containerView.cursor = .arrow
        }
        window?.invalidateCursorRects(for: containerView)
    }
}

private final class PannableImageContainerView: NSView, NSDraggingSource {
    var onPan: ((CGPoint, NSGestureRecognizer.State) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var shouldPan: (() -> Bool)?
    var canBeginDrag: ((CGPoint) -> Bool)?
    var onResolveDragItem: (() -> ClipboardItem?)?
    var isAnnotating = false {
        didSet {
            panGestureRecognizer.isEnabled = !isAnnotating
            doubleClickGestureRecognizer.isEnabled = !isAnnotating
        }
    }
    var cursor: NSCursor = .arrow
    private var didStartDrag = false

    private lazy var panGestureRecognizer: NSPanGestureRecognizer = {
        let gesture = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        gesture.buttonMask = 0x1
        return gesture
    }()

    private lazy var doubleClickGestureRecognizer: NSClickGestureRecognizer = {
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClickGesture(_:)))
        gesture.numberOfClicksRequired = 2
        return gesture
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addGestureRecognizer(panGestureRecognizer)
        addGestureRecognizer(doubleClickGestureRecognizer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(panGestureRecognizer)
        addGestureRecognizer(doubleClickGestureRecognizer)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didStartDrag = false
    }

    @objc
    private func handlePanGesture(_ gesture: NSPanGestureRecognizer) {
        let shouldDrag = shouldPan?() != true || NSEvent.modifierFlags.contains(.option)
        if shouldDrag {
            if gesture.state == .began, !didStartDrag,
               let event = NSApp.currentEvent, event.type == .leftMouseDragged,
               canBeginDrag?(gesture.location(in: self)) == true,
               let dragItem = onResolveDragItem?(), let payload = ClipboardRowDragPayload(item: dragItem) {
                if let missing = payload.firstMissingItem {
                    showMissingItemAlert(for: missing)
                    return
                }
                if let draggingItems = payload.makeDraggingItems(anchor: gesture.location(in: self)) {
                    didStartDrag = true
                    let session = beginDraggingSession(with: draggingItems, event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                }
            }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                didStartDrag = false
            }
            return
        }

        let translation = gesture.translation(in: self)
        if gesture.state == .began || gesture.state == .changed {
            gesture.view?.window?.invalidateCursorRects(for: self)
            cursor = .closedHand
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            cursor = .openHand
            gesture.view?.window?.invalidateCursorRects(for: self)
        }
        onPan?(translation, gesture.state)
    }

    private func showMissingItemAlert(for missing: (url: URL, kind: ClipboardFileSystemItemKind)) {
        let alert = NSAlert()
        alert.messageText = missing.kind == .folder
            ? L10n.tr("drag.missing_folder_title")
            : L10n.tr("drag.missing_file_title")
        alert.informativeText = L10n.format("drag.missing_item_message", missing.url.path)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("menu.ok"))

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc
    private func handleDoubleClickGesture(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDoubleClick?(gesture.location(in: self))
    }
}
