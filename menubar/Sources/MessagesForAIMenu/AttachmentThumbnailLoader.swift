import AppKit
import ImageIO

/// Downscaled thumbnails for image attachments in the Messages transcript.
/// CGImageSource decodes straight to a bounded pixel size (HEIC included)
/// so a photo-heavy thread never holds full-resolution bitmaps; results live
/// in an NSCache and are evicted under memory pressure.
enum AttachmentThumbnailLoader {
  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 160
    return cache
  }()

  static func cached(for url: URL) -> NSImage? {
    cache.object(forKey: url.path as NSString)
  }

  private static let sizeCache: NSCache<NSString, NSValue> = {
    let cache = NSCache<NSString, NSValue>()
    cache.countLimit = 512
    return cache
  }()

  /// Final display size for a thumbnail, from the image header only — no
  /// bitmap decode, so it's cheap enough to call during view construction.
  /// Reserving this exact frame before the async decode keeps transcript
  /// layout stable (a post-snap height change used to push the conversation
  /// off the bottom right after opening a thread).
  static func displaySize(for url: URL, maxWidth: CGFloat = 240, maxHeight: CGFloat = 280) -> CGSize? {
    let key = "\(url.path)|\(maxWidth)x\(maxHeight)" as NSString
    if let cached = sizeCache.object(forKey: key) { return cached.sizeValue }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
          var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
          width > 0, height > 0 else {
      return nil
    }
    if let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
       let orientation = CGImagePropertyOrientation(rawValue: orientationRaw),
       [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) {
      swap(&width, &height)
    }
    let scale = min(maxWidth / width, maxHeight / height, 1)
    let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    sizeCache.setObject(NSValue(size: size), forKey: key)
    return size
  }

  /// Synchronous decode — call off the main thread.
  static func load(url: URL, maxPixel: CGFloat = 640) -> NSImage? {
    if let hit = cache.object(forKey: url.path as NSString) { return hit }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    cache.setObject(image, forKey: url.path as NSString)
    return image
  }
}
