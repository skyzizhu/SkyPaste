import AppKit
import ImageIO

enum ImageAnnotationColor: CaseIterable {
    case black
    case red
    case yellow
    case blue
    case green

    var nsColor: NSColor {
        switch self {
        case .black: .black
        case .red: .systemRed
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .green: .systemGreen
        }
    }

    var localizationKey: String {
        switch self {
        case .black: "preview.annotation_black"
        case .red: "preview.annotation_red"
        case .yellow: "preview.annotation_yellow"
        case .blue: "preview.annotation_blue"
        case .green: "preview.annotation_green"
        }
    }
}

struct ImageAnnotationStroke: Equatable {
    let points: [CGPoint]
    let color: ImageAnnotationColor
    let widthFraction: CGFloat
}

enum ImageAnnotationRenderer {
    private static let maximumExportPixels = 24_000_000.0

    static func pngData(for image: NSImage, strokes: [ImageAnnotationStroke]) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return pngData(for: source, strokes: strokes)
    }

    static func pngData(for imageData: Data, strokes: [ImageAnnotationStroke]) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let pixelCount = Double(width) * Double(height)
        let image: CGImage?
        if width > 0, height > 0, pixelCount > maximumExportPixels || orientation != 1 {
            let ratio = min(1, sqrt(maximumExportPixels / max(pixelCount, 1)))
            let maximumDimension = max(1, Int(Double(max(width, height)) * ratio))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        return pngData(for: image, strokes: strokes)
    }

    private static func pngData(for source: CGImage, strokes: [ImageAnnotationStroke]) -> Data? {
        guard !Task<Never, Never>.isCancelled else { return nil }
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let size = CGSize(width: source.width, height: source.height)
        context.draw(source, in: CGRect(origin: .zero, size: size))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard !Task<Never, Never>.isCancelled else { return nil }
            guard let first = stroke.points.first else { continue }
            let lineWidth = max(1, min(size.width, size.height) * stroke.widthFraction)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(stroke.color.nsColor.cgColor)
            context.setFillColor(stroke.color.nsColor.cgColor)
            let firstPoint = CGPoint(x: first.x * size.width, y: (1 - first.y) * size.height)
            if stroke.points.count == 1 {
                let radius = lineWidth / 2
                context.fillEllipse(in: CGRect(
                    x: firstPoint.x - radius,
                    y: firstPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                continue
            }

            context.beginPath()
            context.move(to: firstPoint)
            for point in stroke.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height))
            }
            context.strokePath()
        }

        guard let rendered = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

final class ImageAnnotationCanvasView: NSView {
    var strokes: [ImageAnnotationStroke] = [] {
        didSet { needsDisplay = true }
    }
    var color: ImageAnnotationColor = .red
    var strokeWidth: CGFloat = 4
    var isEditing = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var onStrokeCompleted: ((ImageAnnotationStroke) -> Void)?

    private var activePoints: [CGPoint] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isEditing {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for stroke in strokes {
            draw(stroke.points, color: stroke.color, lineWidth: stroke.widthFraction * min(bounds.width, bounds.height))
        }
        draw(activePoints, color: color, lineWidth: strokeWidth)
    }

    override func mouseDown(with event: NSEvent) {
        activePoints = [normalizedPoint(for: event)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = normalizedPoint(for: event)
        if let last = activePoints.last, hypot(point.x - last.x, point.y - last.y) < 0.001 {
            return
        }
        activePoints.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !activePoints.isEmpty else { return }
        let completed = ImageAnnotationStroke(
            points: activePoints,
            color: color,
            widthFraction: strokeWidth / max(min(bounds.width, bounds.height), 1)
        )
        activePoints = []
        needsDisplay = true
        onStrokeCompleted?(completed)
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x / max(bounds.width, 1), 0), 1),
            y: min(max(point.y / max(bounds.height, 1), 0), 1)
        )
    }

    private func draw(_ points: [CGPoint], color: ImageAnnotationColor, lineWidth: CGFloat) {
        guard let first = points.first else { return }
        let lineWidth = max(1, lineWidth)
        color.nsColor.setStroke()
        color.nsColor.setFill()
        let firstPoint = CGPoint(x: first.x * bounds.width, y: first.y * bounds.height)

        if points.count == 1 {
            NSBezierPath(ovalIn: CGRect(
                x: firstPoint.x - lineWidth / 2,
                y: firstPoint.y - lineWidth / 2,
                width: lineWidth,
                height: lineWidth
            )).fill()
            return
        }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: firstPoint)
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
        }
        path.stroke()
    }
}
