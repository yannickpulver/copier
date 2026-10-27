import AppKit
import AVFoundation
import CopierCore
import ImageIO
import SwiftUI

/// A small preview of one file, so a day or shoot is recognisable at a glance.
struct Thumbnail: View {
    let file: MediaFile
    var size = CGSize(width: 48, height: 32)

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 4))
        .help(file.name)
        .task(id: file.url) {
            image = await ThumbnailCache.shared.image(for: file, maxPixelSize: Int(size.width * 3))
        }
    }
}

/// Loads thumbnails off the main thread and keeps them for the session, so scrolling
/// and re-rendering never read the card twice.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [URL: NSImage] = [:]

    func image(for file: MediaFile, maxPixelSize: Int) async -> NSImage? {
        if let cached = images[file.url] { return cached }
        let cgImage = file.kind == .video
            ? await Self.videoFrame(file.url, maxPixelSize: maxPixelSize)
            : Self.embeddedPreview(file.url, maxPixelSize: maxPixelSize)
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        images[file.url] = image
        return image
    }

    /// ImageIO takes the JPEG preview a RAW (or the EXIF thumbnail a JPEG) carries and
    /// only decodes the full image when there is none.
    private static func embeddedPreview(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let middle = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        return try? await generator.image(at: middle).image
    }
}
