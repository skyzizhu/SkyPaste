import AppKit
import Foundation

struct IconRenderer {
    let size: CGFloat = 1024

    func render(to outputURL: URL) throws {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill()

        let background = NSBezierPath(roundedRect: canvas, xRadius: size * 0.28, yRadius: size * 0.28)
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        background.fill()

        let points: [CGPoint] = [
            .init(x: 31.9999, y: 11),
            .init(x: 39.4378, y: 15.2718),
            .init(x: 43.7096, y: 22.7097),
            .init(x: 43.7096, y: 31.2532),
            .init(x: 48.2564, y: 33.8734),
            .init(x: 52, y: 40.3667),
            .init(x: 48.2564, y: 46.86),
            .init(x: 39.7129, y: 51.1318),
            .init(x: 31.1694, y: 51.1318),
            .init(x: 26.8977, y: 55.4036),
            .init(x: 19.4043, y: 55.4036),
            .init(x: 11.9109, y: 51.1318),
            .init(x: 8.16724, y: 44.6385),
            .init(x: 8.16724, y: 36.095),
            .init(x: 12.7141, y: 33.4748),
            .init(x: 12.7141, y: 24.9313),
            .init(x: 16.9859, y: 17.4934),
            .init(x: 24.4237, y: 13.2216),
            .init(x: 28.6955, y: 13.2216),
            .init(x: 31.9999, y: 11)
        ]

        let inset = size * 0.09
        let scale = (size - inset * 2) / 64

        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let x = inset + point.x * scale
            let y = size - (inset + point.y * scale)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.line(to: CGPoint(x: x, y: y))
            }
        }
        path.lineJoinStyle = .round
        path.lineWidth = size * 0.045
        NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
        path.stroke()

        let circleRadius = size * 0.115
        let circleRect = NSRect(
            x: (size / 2) - circleRadius,
            y: (size / 2) - circleRadius,
            width: circleRadius * 2,
            height: circleRadius * 2
        )
        let circle = NSBezierPath(ovalIn: circleRect)
        NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.36, alpha: 1).setFill()
        circle.fill()

        image.unlockFocus()

        guard
            let tiffData = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiffData),
            let pngData = rep.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "IconRenderer", code: 1)
        }

        try pngData.write(to: outputURL)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift <output-png-path>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: arguments[1])
try IconRenderer().render(to: outputURL)
