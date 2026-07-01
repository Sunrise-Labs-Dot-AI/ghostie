import AppKit
import AVKit
import SwiftUI

// Renders one message in Messages.app-style: outgoing (from_me) on the
// right with a platform-accented bubble, incoming on the left with a
// gray bubble. The from-me bubble color tracks the draft's platform —
// blue for iMessage, green for WhatsApp — matching each platform's
// native UI. Incoming bubbles stay neutral gray on both platforms.
//
// `showSender` controls whether the sender's name appears above an
// incoming bubble — used by the list view to suppress the label for
// consecutive messages from the same sender (matches Apple's grouping).
//
// `platform` is the parent draft's `effectivePlatform`. It exists ONLY
// to drive the from-me bubble color; incoming bubble color and layout
// are platform-independent. Callers pass `.imessage` to get the legacy
// behavior unchanged (this is also the value Draft.swift's
// `effectivePlatform` returns for legacy drafts without the field).
/// What renders under the most recent outgoing bubble in a transcript —
/// Messages.app-style delivery state ("Delivered" / "Read 2:14 PM") for
/// iMessage, the double tick for WhatsApp.
enum BubbleReceipt: Equatable {
  case text(String)
  case whatsappTicks
}

struct BubbleContextMenuItem: Identifiable {
  enum Icon {
    case emoji(String)
    case system(String)
  }

  let id: String
  let title: String
  let icon: Icon?
  let isEnabled: Bool
  let isSeparator: Bool
  let perform: () -> Void

  init(
    id: String,
    title: String,
    icon: Icon? = nil,
    isEnabled: Bool = true,
    isSeparator: Bool = false,
    perform: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.isEnabled = isEnabled
    self.isSeparator = isSeparator
    self.perform = perform
  }

  static func separator(id: String) -> BubbleContextMenuItem {
    BubbleContextMenuItem(
      id: id,
      title: "",
      isEnabled: false,
      isSeparator: true,
      perform: {}
    )
  }
}

struct ContextBubbleView: View {
  let message: ContextMessage
  let showSender: Bool
  let platform: Platform
  /// Compact surfaces (draft context previews, Don't Ghost) keep the
  /// per-bubble timestamp; the Messages transcript passes false and conveys
  /// time through date separators + hover, like Messages.app.
  var showTimestamp: Bool = true
  var receipt: BubbleReceipt? = nil
  var contextMenuItems: [BubbleContextMenuItem] = []
  /// When true (the Messages transcript, driven by SettingsStore), web-video
  /// links render rich cards that fetch thumbnails and play inline. When false
  /// (the default, and every no-network surface), cards stay offline and tap
  /// opens the browser. See VideoLinkCardView for the privacy rationale.
  var embeddedMediaPreviews: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  /// YouTube/Vimeo links in this message's body, deduped. Cheap substring
  /// pre-filter avoids spinning up NSDataDetector for the overwhelming majority
  /// of messages that contain no video link.
  private var videoLinks: [VideoLink] {
    guard let body = message.body else { return [] }
    let lower = body.lowercased()
    guard lower.contains("youtu") || lower.contains("vimeo") else { return [] }
    return VideoLinkDetector.detect(in: body)
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if message.from_me { Spacer(minLength: 30) }

      VStack(alignment: message.from_me ? .trailing : .leading, spacing: 2) {
        if !message.from_me, showSender {
          Text(message.displayName)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .padding(.leading, 8)
        }

        bubbleInteractionSurface(
          VStack(alignment: message.from_me ? .trailing : .leading, spacing: 3) {
            ForEach(message.attachments, id: \.self) { attachment in
              AttachmentBubbleView(attachment: attachment, fromMe: message.from_me)
            }
            if let body = message.body, !body.isEmpty {
              Text(body)
                .font(DS.Font.bubbleBody)
                .foregroundStyle(textColor)
                .padding(.leading, message.from_me ? 13 : 17)
                .padding(.trailing, message.from_me ? 17 : 13)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .overlay(bubbleBorder)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Rich cards for any YouTube/Vimeo links in the body, below the text.
            ForEach(videoLinks) { link in
              VideoLinkCardView(link: link, embeddedPreviews: embeddedMediaPreviews)
            }
          }
          // Messages.app hangs the tapback capsule off the bubble's TOP corner,
          // overlapping the edge — trailing for inbound, leading for outbound
          // (the side facing the conversation's center). The top padding
          // reserves the overhang so the capsule never collides with the
          // previous row or the sender label.
          .overlay(alignment: message.from_me ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
              ReactionBadgeRow(reactions: message.reactions)
                .offset(x: message.from_me ? -8 : 8, y: -12)
            }
          }
          .padding(.top, message.reactions.isEmpty ? 0 : 12)
          .frame(maxWidth: 430, alignment: message.from_me ? .trailing : .leading)
          .help(message.sentDate.map(timestamp) ?? "")
        )

        if showTimestamp, let date = message.sentDate {
          HStack(spacing: 4) {
            Text(timestamp(date))
            if message.from_me, platform == .whatsapp {
              WhatsAppTicks()
                .foregroundStyle(DS.Color.waTick(colorScheme))
            }
          }
          .font(DS.Font.settingsCaption)
          .monospacedDigit()
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .padding(.horizontal, 8)
        }

        if let receipt {
          receiptRow(receipt)
        }
      }

      if !message.from_me { Spacer(minLength: 30) }
    }
    .frame(maxWidth: .infinity, alignment: message.from_me ? .trailing : .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private func bubbleInteractionSurface<Content: View>(_ content: Content) -> some View {
    if contextMenuItems.isEmpty {
      content
    } else {
      content
        .contentShape(Rectangle())
        .contextMenu {
          bubbleContextMenuContent
        }
        .background(BubbleRightClickMenuBridge(items: contextMenuItems))
    }
  }

  @ViewBuilder
  private var bubbleContextMenuContent: some View {
    ForEach(contextMenuItems) { item in
      if item.isSeparator {
        Divider()
      } else {
        Button {
          item.perform()
        } label: {
          bubbleContextMenuLabel(item)
        }
        .disabled(!item.isEnabled)
      }
    }
  }

  @ViewBuilder
  private func bubbleContextMenuLabel(_ item: BubbleContextMenuItem) -> some View {
    if let icon = item.icon {
      Label {
        Text(item.title)
      } icon: {
        switch icon {
        case .emoji(let emoji):
          Text(emoji)
            .font(.custom("Apple Color Emoji", size: 13))
        case .system(let name):
          Image(systemName: name)
        }
      }
    } else {
      Text(item.title)
    }
  }

  @ViewBuilder
  private func receiptRow(_ receipt: BubbleReceipt) -> some View {
    switch receipt {
    case .text(let text):
      Text(text)
        .font(DS.Font.settingsCaption)
        .monospacedDigit()
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .padding(.horizontal, 8)
        .padding(.top, 1)
    case .whatsappTicks:
      WhatsAppTicks()
        .foregroundStyle(DS.Color.waTick(colorScheme))
        .padding(.horizontal, 8)
        .padding(.top, 1)
    }
  }

  @ViewBuilder
  private var bubbleBackground: some View {
    let shape = DSBubbleShape(tail: message.from_me ? .outgoing : .incoming)
    if message.from_me, platform == .imessage {
      shape.fill(
        LinearGradient(
          colors: [DS.Color.imsgBlueTop, DS.Color.imsgBlueBottom],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    } else {
      shape.fill(bubbleFill)
    }
  }

  @ViewBuilder
  private var bubbleBorder: some View {
    if !message.from_me, platform == .whatsapp {
      DSBubbleShape(tail: .incoming)
        .stroke(DS.Color.line2(colorScheme), lineWidth: 1)
    }
  }

  private var bubbleFill: Color {
    switch (message.from_me, platform) {
    case (true, .imessage):
      return DS.Color.imsgBlueBottom
    case (false, .imessage):
      return DS.Color.imsgInBg(colorScheme)
    case (true, .whatsapp):
      return DS.Color.waOutBg(colorScheme)
    case (false, .whatsapp):
      return colorScheme == .dark ? DS.Color.waInBg(colorScheme) : DS.Color.g160(colorScheme)
    }
  }

  private var textColor: Color {
    switch (message.from_me, platform) {
    case (true, .imessage):
      return DS.Color.imsgOutText
    case (false, .imessage):
      return DS.Color.imsgInText(colorScheme)
    case (true, .whatsapp):
      return DS.Color.waOutText(colorScheme)
    case (false, .whatsapp):
      return DS.Color.waInText(colorScheme)
    }
  }

  // Short timestamp: "3:08 PM" if today, otherwise include the actual date
  // so older Don't Ghost context is not ambiguous ("Jun 5, 3:08 PM").
  private func timestamp(_ date: Date) -> String {
    let cal = Calendar.current
    let formatter = DateFormatter()
    if cal.isDateInToday(date) {
      formatter.timeStyle = .short
      formatter.dateStyle = .none
    } else if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
      formatter.dateFormat = "MMM d, h:mm a"
    } else {
      formatter.dateFormat = "MMM d, yyyy, h:mm a"
    }
    return formatter.string(from: date)
  }

  private var accessibilityLabel: String {
    var parts = [message.displayName]
    if let body = message.body, !body.isEmpty {
      parts.append(body)
    } else {
      parts.append("empty message")
    }
    // The bubble collapses its children (`.accessibilityElement(children:
    // .ignore)`), so the tapback capsule's label must be merged here or
    // VoiceOver never reads it.
    if !message.reactions.isEmpty {
      parts.append(ReactionBadgePolicy.accessibilityLabel(message.reactions))
    }
    if let date = message.sentDate {
      parts.append(timestamp(date))
    }
    return parts.joined(separator: ", ")
  }
}

private struct BubbleRightClickMenuBridge: NSViewRepresentable {
  let items: [BubbleContextMenuItem]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.wantsLayer = false
    context.coordinator.attach(to: view, items: items)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.attach(to: nsView, items: items)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator: NSObject {
    private weak var view: NSView?
    private var monitor: Any?
    private var items: [BubbleContextMenuItem] = []

    func attach(to view: NSView, items: [BubbleContextMenuItem]) {
      self.view = view
      self.items = items
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func detach() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
      view = nil
      items = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
            !items.isEmpty,
            let view,
            let window = view.window,
            event.window === window else {
        return event
      }
      let point = view.convert(event.locationInWindow, from: nil)
      guard view.bounds.contains(point) else { return event }
      let menu = makeMenu()
      menu.popUp(positioning: nil, at: point, in: view)
      return nil
    }

    private func makeMenu() -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for item in items {
        if item.isSeparator {
          menu.addItem(.separator())
          continue
        }
        let menuItem = NSMenuItem(title: menuTitle(for: item), action: #selector(performMenuItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
        menuItem.isEnabled = item.isEnabled
        if case .system(let name) = item.icon {
          menuItem.image = NSImage(systemSymbolName: name, accessibilityDescription: item.title)
        }
        menu.addItem(menuItem)
      }
      return menu
    }

    private func menuTitle(for item: BubbleContextMenuItem) -> String {
      if case .emoji(let emoji) = item.icon {
        return "\(emoji)  \(item.title)"
      }
      return item.title
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String,
            let item = items.first(where: { $0.id == id }),
            item.isEnabled else {
        return
      }
      item.perform()
    }
  }
}

/// One attachment inside a bubble stack. Images render as Messages.app-style
/// bare rounded thumbnails (decoded off-main, bounded size, click to open);
/// everything else renders as a quiet file chip.
struct AttachmentBubbleView: View {
  let attachment: MessageAttachmentRef
  let fromMe: Bool
  @State private var thumbnail: NSImage?
  @State private var thumbnailFailed = false
  // Video state: poster frame + duration (loaded once), and whether the user
  // has tapped to swap the poster for an inline player.
  @State private var poster: NSImage?
  @State private var videoDuration: Double?
  @State private var videoFailed = false
  @State private var player: AVPlayer?
  // WhatsApp on-demand download state: the local file once fetched, plus
  // in-flight / failed flags for the tap-to-load card.
  @State private var downloadedURL: URL?
  @State private var downloading = false
  @State private var downloadFailed = false
  @Environment(\.colorScheme) private var colorScheme

  // 16:9 reserved box for video posters. Reserving a fixed aspect (rather than
  // the clip's true size, which is only knowable async) keeps transcript layout
  // stable; the poster is scaledToFit inside, letterboxed if needed.
  private static let videoWidth: CGFloat = 240
  private static let videoHeight: CGFloat = 135

  /// The playable/renderable file: a freshly downloaded WhatsApp payload if we
  /// have one, otherwise the local on-disk attachment (iMessage).
  private var effectiveURL: URL? { downloadedURL ?? attachment.resolvedURL }

  var body: some View {
    if let url = effectiveURL, attachment.isVideo, !videoFailed {
      videoThumbnail(url)
    } else if let url = effectiveURL, attachment.isImage, !thumbnailFailed {
      imageThumbnail(url)
    } else if attachment.isDownloadableWhatsAppMedia {
      whatsappMediaCard
    } else {
      filePill
    }
  }

  // Tap-to-load card for WhatsApp media that isn't on disk yet. A tap asks the
  // daemon to download + decrypt the payload; image/video then render inline,
  // documents/voice open in the default app.
  private var whatsappMediaCard: some View {
    let isVid = attachment.isVideo
    let isImg = attachment.isImage
    let icon = downloadFailed ? "exclamationmark.triangle"
      : isVid ? "play.circle" : (isImg ? "arrow.down.circle" : "doc.fill")
    let label = downloadFailed ? "Couldn’t load"
      : downloading ? "Loading…"
      : isVid ? "Tap to load video"
      : isImg ? "Tap to load photo"
      : attachment.displayName
    return ZStack {
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .fill(DS.Color.g160(colorScheme))
      VStack(spacing: 6) {
        if downloading {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: icon)
            .font(.system(size: 30))
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Text(label)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(8)
    }
    .frame(width: Self.videoWidth, height: isVid ? Self.videoHeight : 150)
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
    )
    .contentShape(Rectangle())
    .onTapGesture { Task { await downloadWhatsAppMedia() } }
    .accessibilityLabel(label)
    .accessibilityAddTraits(.isButton)
  }

  private func downloadWhatsAppMedia() async {
    guard !downloading,
          let jid = attachment.whatsappThreadJID,
          let mid = attachment.whatsappMessageID else { return }
    downloading = true
    downloadFailed = false
    defer { downloading = false }
    do {
      let result = try await WhatsAppRPCClient.downloadMedia(threadJID: jid, messageID: mid)
      let url = URL(fileURLWithPath: result.path)
      if attachment.isVideo || attachment.isImage {
        downloadedURL = url   // re-renders into the inline video/image branch
      } else {
        NSWorkspace.shared.open(url)  // documents / voice notes open externally
      }
    } catch {
      downloadFailed = true
    }
  }

  @ViewBuilder
  private func videoThumbnail(_ url: URL) -> some View {
    Group {
      if let player {
        // Inline playback — swapped in on tap. Uses AppKit's AVPlayerView
        // (NSViewRepresentable) rather than SwiftUI's VideoPlayer: on macOS 26,
        // instantiating VideoPlayer aborts in _AVKit_SwiftUI generic-metadata setup
        // (getSuperclassMetadata fatalError) the moment the player swaps in. AVPlayerView
        // gives the same inline transport controls without that crashing path.
        InlineAVPlayerView(player: player)
          .onAppear { player.play() }
      } else {
        ZStack {
          if let poster {
            Image(nsImage: poster)
              .resizable()
              .scaledToFit()
          } else {
            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
              .fill(DS.Color.g160(colorScheme))
              .overlay(ProgressView().controlSize(.small))
          }
          // Play affordance over the poster.
          Image(systemName: "play.circle.fill")
            .font(.system(size: 38))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(radius: 3)
          if let videoDuration {
            Text(VideoPosterLoader.formatDuration(videoDuration))
              .font(DS.Font.monoMicro)
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Capsule().fill(.black.opacity(0.55)))
              .padding(6)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { player = AVPlayer(url: url) }
        .accessibilityLabel(
          videoDuration.map { "Video attachment, \(VideoPosterLoader.formatDuration($0))" }
            ?? "Video attachment"
        )
        .accessibilityAddTraits(.isButton)
      }
    }
    .frame(width: Self.videoWidth, height: Self.videoHeight)
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
    )
    .task(id: url.path) {
      if let cached = VideoPosterLoader.cachedPoster(for: url) {
        poster = cached.image
        videoDuration = cached.duration
        return
      }
      if let loaded = await VideoPosterLoader.load(url: url) {
        poster = loaded.image
        videoDuration = loaded.duration
      } else {
        videoFailed = true
      }
    }
  }

  @ViewBuilder
  private func imageThumbnail(_ url: URL) -> some View {
    // Reserve the exact final size before the bitmap decodes (header-only
    // read) so the bubble never changes height after the bottom snap.
    let reserved = AttachmentThumbnailLoader.displaySize(for: url) ?? CGSize(width: 200, height: 140)
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFit()
      } else {
        RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
          .fill(DS.Color.g160(colorScheme))
          .overlay(
            ProgressView()
              .controlSize(.small)
          )
      }
    }
    .frame(width: reserved.width, height: reserved.height)
    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
    )
    .onTapGesture {
      NSWorkspace.shared.open(url)
    }
    .task(id: url.path) {
      if let cached = AttachmentThumbnailLoader.cached(for: url) {
        thumbnail = cached
        return
      }
      let loaded = await Task.detached(priority: .utility) {
        AttachmentThumbnailLoader.load(url: url)
      }.value
      if let loaded {
        thumbnail = loaded
      } else {
        thumbnailFailed = true
      }
    }
    .accessibilityLabel("Image attachment")
    .accessibilityAddTraits(.isButton)
  }

  private var filePill: some View {
    Button {
      if let url = attachment.resolvedURL {
        NSWorkspace.shared.open(url)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "doc.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(DS.Color.ink3(colorScheme))
        VStack(alignment: .leading, spacing: 1) {
          Text(attachment.displayName)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
          if attachment.byteCount > 0 {
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: 240, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
          .fill(DS.Color.g160(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
          .strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
    .disabled(attachment.resolvedURL == nil)
    .accessibilityLabel("Attachment: \(attachment.displayName)")
  }
}

/// Messages.app-style time markers: a centered "Today 2:14 PM" appears at the
/// start of the transcript and wherever the conversation pauses for more than
/// an hour, instead of stamping a time under every bubble.
enum TranscriptSeparatorPolicy {
  static let gap: TimeInterval = 3600

  static func shouldInsertSeparator(previous: ContextMessage?, message: ContextMessage) -> Bool {
    guard let date = message.sentDate else { return false }
    guard let previous, let previousDate = previous.sentDate else { return true }
    return date.timeIntervalSince(previousDate) > gap
  }

  /// Consecutive bubbles from the same sender within a minute sit tight
  /// (Messages.app's grouping); a turn change or pause gets air.
  static func isFollowOn(previous: ContextMessage?, message: ContextMessage, maxGap: TimeInterval = 60) -> Bool {
    guard let previous,
          previous.from_me == message.from_me,
          previous.sender_handle == message.sender_handle,
          let previousDate = previous.sentDate,
          let date = message.sentDate else {
      return false
    }
    return date.timeIntervalSince(previousDate) <= maxGap
  }

  static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> (day: String, time: String) {
    let timeFormatter = DateFormatter()
    timeFormatter.timeStyle = .short
    timeFormatter.dateStyle = .none
    let time = timeFormatter.string(from: date)

    if calendar.isDateInToday(date) { return ("Today", time) }
    if calendar.isDateInYesterday(date) { return ("Yesterday", time) }

    let dayFormatter = DateFormatter()
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
       date >= weekAgo {
      dayFormatter.dateFormat = "EEEE"
    } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      dayFormatter.dateFormat = "EEE, MMM d"
    } else {
      dayFormatter.dateFormat = "MMM d, yyyy"
    }
    return (dayFormatter.string(from: date), time)
  }
}

struct TranscriptDateSeparator: View {
  let date: Date
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let label = TranscriptSeparatorPolicy.label(for: date)
    return HStack {
      Spacer()
      (Text(label.day).fontWeight(.semibold) + Text(" \(label.time)"))
        .font(DS.Font.settingsCaption)
        .monospacedDigit()
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Spacer()
    }
    .padding(.top, DS.Space.l)
    .padding(.bottom, DS.Space.xs)
    .accessibilityLabel("\(label.day) \(label.time)")
  }
}

struct WhatsAppTicks: View {
  var body: some View {
    ZStack {
      Image(systemName: "checkmark")
        .font(.system(size: 8.5, weight: .bold))
        .offset(x: -2)
      Image(systemName: "checkmark")
        .font(.system(size: 8.5, weight: .bold))
        .offset(x: 2)
    }
    .frame(width: 13, height: 9)
    .accessibilityLabel("Read")
  }
}

/// Display policy for the tapback capsule, kept pure so it's unit testable:
/// reactions collapse per kind preserving first-seen order ("❤️ 2 👍" rather
/// than one glyph per reactor), and the accessibility label reads the way
/// Messages.app's VoiceOver does ("Loved by Alice and Bob").
enum ReactionBadgePolicy {
  struct Group: Equatable {
    let kind: MessageReaction.Kind
    let emoji: String?
    let count: Int

    var id: String { "\(kind.rawValue)|\(emoji ?? "")" }
  }

  static func collapsed(_ reactions: [MessageReaction]) -> [Group] {
    struct Key: Hashable {
      let kind: MessageReaction.Kind
      let emoji: String?
    }
    var order: [Key] = []
    var counts: [Key: Int] = [:]
    for reaction in reactions {
      let key = Key(kind: reaction.kind, emoji: normalizedEmoji(reaction.emoji))
      if counts[key] == nil { order.append(key) }
      counts[key, default: 0] += 1
    }
    return order.map { Group(kind: $0.kind, emoji: $0.emoji, count: counts[$0] ?? 0) }
  }

  static func accessibilityLabel(_ reactions: [MessageReaction]) -> String {
    struct Key: Hashable {
      let kind: MessageReaction.Kind
      let emoji: String?
    }
    var order: [Key] = []
    var reactors: [Key: [String]] = [:]
    for reaction in reactions {
      let key = Key(kind: reaction.kind, emoji: normalizedEmoji(reaction.emoji))
      if reactors[key] == nil { order.append(key) }
      let name = reaction.from_me
        ? "You"
        : (reaction.sender_name ?? reaction.sender_handle ?? "someone")
      reactors[key, default: []].append(name)
    }
    return order
      .map { "\(verb($0.kind, emoji: $0.emoji)) by \(joined(reactors[$0] ?? []))" }
      .joined(separator: ", ")
  }

  static func displayGlyph(kind: MessageReaction.Kind, emoji: String? = nil) -> String {
    if let custom = normalizedEmoji(emoji) { return custom }
    switch kind {
    case .loved: return "❤️"
    case .liked: return "👍"
    case .disliked: return "👎"
    case .laughed: return "😂"
    case .emphasized: return "‼️"
    case .questioned: return "❓"
    case .emoji, .reacted: return "🙂"
    }
  }

  private static func verb(_ kind: MessageReaction.Kind, emoji: String?) -> String {
    if let emoji = normalizedEmoji(emoji) {
      return "Reacted \(emoji)"
    }
    switch kind {
    case .loved: return "Loved"
    case .liked: return "Liked"
    case .disliked: return "Disliked"
    case .laughed: return "Laughed at"
    case .emphasized: return "Emphasized"
    case .questioned: return "Questioned"
    case .emoji: return "Reacted with emoji"
    case .reacted: return "Reacted to"
    }
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private static func joined(_ names: [String]) -> String {
    switch names.count {
    case 0: return "someone"
    case 1: return names[0]
    case 2: return "\(names[0]) and \(names[1])"
    default:
      return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
    }
  }
}

private struct ReactionBadgeRow: View {
  let reactions: [MessageReaction]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 4) {
      ForEach(ReactionBadgePolicy.collapsed(reactions), id: \.id) { group in
        HStack(spacing: 2) {
          reactionGlyph(kind: group.kind, emoji: group.emoji)
          if group.count > 1 {
            Text("\(group.count)")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(DS.Color.ink2(colorScheme))
          }
        }
      }
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 3)
    .background(Capsule().fill(DS.Color.g050(colorScheme)))
    .overlay(Capsule().strokeBorder(DS.Color.line(colorScheme), lineWidth: 1))
    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 3, x: 0, y: 1)
    .accessibilityLabel(ReactionBadgePolicy.accessibilityLabel(reactions))
  }

  @ViewBuilder
  private func reactionGlyph(kind: MessageReaction.Kind, emoji: String?) -> some View {
    Text(ReactionBadgePolicy.displayGlyph(kind: kind, emoji: emoji))
      .font(.custom("Apple Color Emoji", size: 13))
      .foregroundStyle(DS.Color.ink(colorScheme))
      .fixedSize()
  }
}

/// AppKit `AVPlayerView` wrapped for SwiftUI. Used instead of SwiftUI's `VideoPlayer`
/// because the latter aborts in `_AVKit_SwiftUI` generic-metadata instantiation on
/// macOS 26 (getSuperclassMetadata fatalError) when it's swapped in. `AVPlayerView`
/// provides the same inline transport controls through the AppKit path.
private struct InlineAVPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .inline
    view.videoGravity = .resizeAspect
    return view
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    if nsView.player !== player { nsView.player = player }
  }
}
