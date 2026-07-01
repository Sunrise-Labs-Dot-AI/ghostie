import Foundation

/// A web-video link found in a message body (YouTube / Vimeo). Pure value type
/// so the detector is unit-testable without any UI or network. The card view
/// decides whether to fetch a thumbnail / embed a player based on the user's
/// privacy setting — this type only models WHICH video a URL points at.
struct VideoLink: Hashable, Identifiable {
  enum Provider: String, Hashable {
    case youtube
    case vimeo

    var label: String {
      switch self {
      case .youtube: return "YouTube"
      case .vimeo: return "Vimeo"
      }
    }
  }

  let provider: Provider
  let videoID: String
  /// The original URL as it appeared in the message — the open-in-browser target.
  let watchURL: URL

  var id: String { "\(provider.rawValue):\(videoID)" }

  /// Static poster image, derived from the video ID with no API call. Only
  /// FETCHED when the user has opted into embedded media previews; deriving the
  /// URL is free. Vimeo has no ID-derivable thumbnail (needs oEmbed), so nil.
  var thumbnailURL: URL? {
    switch provider {
    case .youtube: return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    case .vimeo: return nil
    }
  }

  /// Privacy-preserving embed target for inline playback (opt-in only).
  /// youtube-nocookie defers Google's tracking cookies until playback; Vimeo's
  /// player host is the equivalent.
  var embedURL: URL? {
    switch provider {
    case .youtube: return URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)")
    case .vimeo: return URL(string: "https://player.vimeo.com/video/\(videoID)")
    }
  }
}

/// Extracts video links from message text. NSDataDetector finds the URLs (so we
/// match Messages.app's own link grammar, including bare URLs); a small
/// provider parser classifies each and pulls the video ID.
enum VideoLinkDetector {
  private static let youtubeIDChars = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  )

  /// All distinct video links in `text`, in first-seen order (deduped by
  /// provider+id, so a repeated link renders one card).
  static func detect(in text: String) -> [VideoLink] {
    guard !text.isEmpty,
          let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var seen = Set<String>()
    var out: [VideoLink] = []
    detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
      guard let url = match?.url, let link = classify(url), seen.insert(link.id).inserted else { return }
      out.append(link)
    }
    return out
  }

  /// Classify a single URL as a known video link, or nil. Exposed for tests.
  static func classify(_ url: URL) -> VideoLink? {
    guard let host = url.host?.lowercased() else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let pathParts = url.path.split(separator: "/").map(String.init)

    // youtu.be/<id>
    if host == "youtu.be", let id = pathParts.first, isYouTubeID(id) {
      return VideoLink(provider: .youtube, videoID: id, watchURL: url)
    }

    if host == "youtube.com" || host.hasSuffix(".youtube.com")
        || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
      // /watch?v=<id>
      if let v = components?.queryItems?.first(where: { $0.name == "v" })?.value, isYouTubeID(v) {
        return VideoLink(provider: .youtube, videoID: v, watchURL: url)
      }
      // /shorts/<id>, /embed/<id>, /v/<id>, /live/<id>
      if pathParts.count >= 2,
         ["shorts", "embed", "v", "live"].contains(pathParts[0]),
         isYouTubeID(pathParts[1]) {
        return VideoLink(provider: .youtube, videoID: pathParts[1], watchURL: url)
      }
    }

    // vimeo.com/<digits> or player.vimeo.com/video/<digits>
    if host == "vimeo.com" || host.hasSuffix(".vimeo.com") {
      if let id = pathParts.last, isVimeoID(id) {
        return VideoLink(provider: .vimeo, videoID: id, watchURL: url)
      }
    }

    return nil
  }

  static func isYouTubeID(_ s: String) -> Bool {
    s.count == 11 && s.unicodeScalars.allSatisfy { youtubeIDChars.contains($0) }
  }

  static func isVimeoID(_ s: String) -> Bool {
    s.count >= 6 && s.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
