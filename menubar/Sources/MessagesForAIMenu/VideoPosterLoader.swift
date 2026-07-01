import AVFoundation
import AppKit

/// Poster frames (and duration) for video attachments in the Messages
/// transcript. Mirrors AttachmentThumbnailLoader's discipline — a single
/// frame is decoded to a bounded pixel size off the main actor, results live
/// in an NSCache evicted under memory pressure — but uses AVFoundation rather
/// than ImageIO because the source is a movie container, not a still.
///
/// Everything here is local: the file is the on-disk attachment Messages.app
/// already wrote. No network, no opt-in. The inline AVKit player (in
/// AttachmentBubbleView) plays the same local URL.
enum VideoPosterLoader {
  struct Poster {
    let image: NSImage
    /// Seconds, when AVFoundation could read it; nil when unknown.
    let duration: Double?
  }

  private static let posterCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 80
    return cache
  }()
  private static let durationCache: NSCache<NSString, NSNumber> = {
    let cache = NSCache<NSString, NSNumber>()
    cache.countLimit = 512
    return cache
  }()

  static func cachedPoster(for url: URL) -> Poster? {
    guard let image = posterCache.object(forKey: url.path as NSString) else { return nil }
    let duration = durationCache.object(forKey: url.path as NSString)?.doubleValue
    return Poster(image: image, duration: duration)
  }

  /// Decode a poster frame near the start of the clip plus the duration.
  /// Async (AVFoundation's modern API is async) — call from a `.task`. Returns
  /// nil when the asset has no readable video frame (corrupt / audio-only /
  /// unsupported codec), in which case the caller shows the file chip instead.
  static func load(url: URL, maxPixel: CGFloat = 640) async -> Poster? {
    if let hit = cachedPoster(for: url) { return hit }

    let asset = AVURLAsset(url: url)
    let durationSeconds: Double? = await {
      guard let d = try? await asset.load(.duration) else { return nil }
      let seconds = CMTimeGetSeconds(d)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }()

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true   // honor rotation metadata
    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
    // A hair into the clip dodges the all-black first frame some encoders emit;
    // clamp to the midpoint of very short clips so we never seek past the end.
    let target = CMTime(seconds: min(0.5, (durationSeconds ?? 1) / 2), preferredTimescale: 600)

    guard let cgImage = try? await generator.image(at: target).image else { return nil }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

    posterCache.setObject(image, forKey: url.path as NSString)
    if let durationSeconds {
      durationCache.setObject(NSNumber(value: durationSeconds), forKey: url.path as NSString)
    }
    return Poster(image: image, duration: durationSeconds)
  }

  /// "0:09", "1:24", "1:02:03" — compact like Messages' video duration badge.
  static func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
  }
}
