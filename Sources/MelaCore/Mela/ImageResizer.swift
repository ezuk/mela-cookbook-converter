import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

/// Prepares book photos for Mela: JPEG or PNG at least 300 px on the short side,
/// re-encoded as JPEG at about 512 px on the long side.
public enum ImageResizer {
    public static let longEdge = 512
    public static let minimumShortEdge = 300

    /// Returns JPEG data ready for Mela, or nil if the image is too small or unreadable.
    public static func prepare(_ data: Data) -> Data? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              min(w, h) >= minimumShortEdge else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
        #else
        // No image codecs on Linux: pass JPEG and PNG through unchanged when they're big enough.
        guard let size = pixelSize(data), min(size.width, size.height) >= minimumShortEdge else { return nil }
        return data
        #endif
    }

    /// Reads width and height from JPEG or PNG headers.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(min(data.count, 512 * 1024)))
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            return (w, h)
        }
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (w, h)
            }
            i += 2 + length
        }
        return nil
    }
}
