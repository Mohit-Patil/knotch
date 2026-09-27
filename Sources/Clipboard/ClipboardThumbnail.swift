import AppKit
import ImageIO
import SwiftUI

/// Decode only display-sized pixels. Original payloads never become NSImages in
/// the history UI; the cache is limited independently of the history's disk quota.
actor ClipboardThumbnails {
    static let shared = ClipboardThumbnails()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 32
    }

    func image(for entry: ClipboardEntry) -> CGImage? {
        let key = entry.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image }
        let source: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let data = entry.data {
            source = CGImageSourceCreateWithData(data as CFData, options)
        } else if entry.validPayloadNames, let name = entry.dataFile, let directory = entry.payloadDirectory {
            source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, options)
        } else { return nil }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 420,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func clear() { cache.removeAllObjects() }
}

struct ClipboardThumbnail: View {
    let entry: ClipboardEntry
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.white.opacity(0.42)) }
        }
        .task(id: entry.id) {
            let pixels = await ClipboardThumbnails.shared.image(for: entry)
            guard !Task.isCancelled else { return }
            image = pixels.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
