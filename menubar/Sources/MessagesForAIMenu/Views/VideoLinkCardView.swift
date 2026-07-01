import AppKit
import SwiftUI
import WebKit

/// A Messages-style rich card for a YouTube/Vimeo link found in a message body.
///
/// Privacy posture (matches the product's read-only / metadata-only stance):
/// - DEFAULT (embeddedPreviews off): renders with NO network at all — a
///   provider-tinted placeholder + label, tap opens the system browser.
/// - OPT-IN (embeddedPreviews on): fetches the static provider thumbnail and
///   plays inline in a non-persistent (cookie-free) youtube-nocookie WKWebView.
///
/// The single `embeddedPreviews` flag gates BOTH the thumbnail fetch and the
/// inline embed, so turning it off means this feature makes zero outbound
/// requests on the user's behalf.
struct VideoLinkCardView: View {
  let link: VideoLink
  /// Driven by SettingsStore.embeddedMediaPreviews. Off = no network, browser.
  var embeddedPreviews: Bool

  @State private var thumbnail: NSImage?
  @State private var playing = false
  @Environment(\.colorScheme) private var colorScheme

  private static let width: CGFloat = 240
  private static let posterHeight: CGFloat = 135

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      poster
      footer
    }
    .frame(width: Self.width)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .fill(DS.Color.g160(colorScheme))
    )
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var poster: some View {
    if playing, let embed = link.embedURL {
      WebVideoPlayerView(url: embed)
        .frame(width: Self.width, height: Self.posterHeight)
    } else {
      ZStack {
        if let thumbnail {
          Image(nsImage: thumbnail)
            .resizable()
            .scaledToFill()
        } else {
          // No-network placeholder: a flat provider-tinted field.
          (link.provider == .youtube ? Color.red : Color.blue)
            .opacity(0.16)
        }
        Image(systemName: "play.circle.fill")
          .font(.system(size: 38))
          .foregroundStyle(.white.opacity(0.92))
          .shadow(radius: 3)
      }
      .frame(width: Self.width, height: Self.posterHeight)
      .clipped()
      .contentShape(Rectangle())
      .onTapGesture(perform: activate)
      .accessibilityLabel("\(link.provider.label) video")
      .accessibilityAddTraits(.isButton)
      .task(id: link.id) { await loadThumbnailIfAllowed() }
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      Image(systemName: "play.rectangle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(link.provider == .youtube ? Color.red : Color.blue)
      Text(link.provider.label)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Spacer(minLength: 4)
      // The open-in-browser glyph appears only when we WON'T embed — a hint
      // that tapping leaves the app.
      if !embeddedPreviews {
        Image(systemName: "arrow.up.forward.app")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
  }

  private func activate() {
    if embeddedPreviews, link.embedURL != nil {
      playing = true
    } else {
      NSWorkspace.shared.open(link.watchURL)
    }
  }

  private func loadThumbnailIfAllowed() async {
    guard embeddedPreviews, thumbnail == nil, let url = link.thumbnailURL else { return }
    if let image = await VideoLinkThumbnailLoader.load(url) {
      thumbnail = image
    }
  }
}

/// Cookie-free thumbnail fetcher. Uses an ephemeral URLSession (no persistent
/// cookies / cache) so a fetched poster doesn't leave identifying state. Only
/// called when embedded previews are enabled.
enum VideoLinkThumbnailLoader {
  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 80
    return cache
  }()

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.requestCachePolicy = .returnCacheDataElseLoad
    config.timeoutIntervalForRequest = 8
    return URLSession(configuration: config)
  }()

  static func load(_ url: URL) async -> NSImage? {
    if let hit = cache.object(forKey: url.absoluteString as NSString) { return hit }
    guard let (data, response) = try? await session.data(from: url),
          let http = response as? HTTPURLResponse, http.statusCode == 200,
          let image = NSImage(data: data) else { return nil }
    cache.setObject(image, forKey: url.absoluteString as NSString)
    return image
  }
}

/// Minimal WKWebView host for the opt-in inline embed. Non-persistent data
/// store = no cookies survive the view; JS is required for the player but the
/// nocookie/player host is the only thing it loads.
struct WebVideoPlayerView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    if webView.url != url {
      webView.load(URLRequest(url: url))
    }
  }
}
