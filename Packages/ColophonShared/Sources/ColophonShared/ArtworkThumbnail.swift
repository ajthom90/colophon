import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales encoded cover-art bytes to a small thumbnail before they're written into the App
/// Group container (`SharedStore.writeArtwork`) — companion surfaces (the continue-listening
/// widget) only need a coarse cover, and the container is SHARED disk space, not a private cache,
/// so keeping it small matters.
///
/// Uses ImageIO's thumbnail generation (`CGImageSourceCreateThumbnailAtIndex`), which decodes
/// directly at the target size rather than materializing the full-resolution source image in
/// memory first — cheaper than "decode full image, then resize" for a typical few-hundred-KB
/// cover. A pure `Data -> Data?` function with no actor/UIKit·AppKit dependency, so it runs
/// happily off the main actor and is unit-testable with no simulator or widget host.
public enum ArtworkThumbnail {
    /// Returns JPEG-encoded thumbnail bytes no larger than `maxPixelSize` on the longest edge, or
    /// `nil` when `data` isn't a decodable image. Corrupt/empty `data` is tolerated as a miss (the
    /// caller falls back to no artwork), never a crash.
    public static func downscale(_ data: Data, maxPixelSize: Int) -> Data? {
        guard !data.isEmpty, maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(destination, thumbnail, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
