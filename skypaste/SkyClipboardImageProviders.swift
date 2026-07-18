import AppKit
import Foundation
import ImageIO

final class ClipboardPreviewImageProvider {
    static let shared = ClipboardPreviewImageProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.huaibor.skypaste.preview-image-provider", qos: .userInitiated)

    func loadThumbnail(at url: URL, maxPixelSize: Int, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            let image = self.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
            if let image {
                self.cache.setObject(image, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func loadThumbnail(from data: Data, cacheKey rawCacheKey: String, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = rawCacheKey as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            let image = NSImage(data: data)
            if let image {
                self.cache.setObject(image, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func makeThumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return NSImage(contentsOf: url)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return NSImage(contentsOf: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

final class ClipboardSourceAppIconProvider {
    static let shared = ClipboardSourceAppIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.huaibor.skypaste.source-app-icon-provider", qos: .utility)

    func loadIcon(for sourceApp: ClipboardSourceApp, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = sourceApp.bundleID as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        queue.async {
            let image: NSImage?
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceApp.bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                image = icon
            } else {
                image = nil
            }

            if let image {
                self.cache.setObject(image, forKey: cacheKey)
            }

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
