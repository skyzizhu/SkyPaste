import AppKit
import SwiftUI

struct ImagePreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    let onCopy: () -> Void
    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnimationNonce = 0

    private var image: NSImage? {
        item.previewImage
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("preview.title"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
                    }

                    if item.supportsSharing {
                        PreviewHeaderShareButton(item: item)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Divider()

            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [
                                        Color.white.opacity(0.04),
                                        Color(nsColor: .controlBackgroundColor)
                                    ]
                                    : [
                                        Color.black.opacity(0.05),
                                        Color.white.opacity(0.52)
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        }

                    if let image {
                        MagnifiableImagePreviewRepresentable(
                            image: image,
                            zoomScale: $zoomScale,
                            zoomAnimationNonce: zoomAnimationNonce,
                            availableSize: CGSize(
                                width: max(proxy.size.width - 120, 280),
                                height: max(proxy.size.height - 120, 280)
                            )
                        )
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
                .padding(24)
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
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.4), 5)
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

    private let containerView = PannableImageContainerView()
    private let imageView = NSImageView()
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
        imageView.image = image
        baseImageSize = fittedImageSize(imageSize: imageDisplaySize(for: image), availableSize: availableSize)
        let scaleChanged = abs(currentScale - zoomScale) > 0.001
        if scaleChanged {
            currentScale = zoomScale
        }
        applyLayout(animated: animated && scaleChanged)
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
        containerView.onPan = { [weak self] translation, state in
            self?.handlePan(translation: translation, state: state)
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
        scroll(to: metrics.targetOrigin)
        updateCursor()
    }

    private func layoutMetrics() -> (containerSize: CGSize, imageFrame: CGRect, targetOrigin: CGPoint) {
        let scaledSize = CGSize(
            width: max(120, baseImageSize.width * currentScale),
            height: max(120, baseImageSize.height * currentScale)
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
        let scale = min(widthScale, heightScale, 1)

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
        if canPanContent {
            containerView.cursor = .openHand
        } else {
            containerView.cursor = .arrow
        }
        window?.invalidateCursorRects(for: containerView)
    }
}

private final class PannableImageContainerView: NSView {
    var onPan: ((CGPoint, NSGestureRecognizer.State) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var cursor: NSCursor = .arrow

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

    @objc
    private func handlePanGesture(_ gesture: NSPanGestureRecognizer) {
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

    @objc
    private func handleDoubleClickGesture(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDoubleClick?(gesture.location(in: self))
    }
}
