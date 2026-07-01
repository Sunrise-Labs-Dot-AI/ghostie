import SwiftUI
import XCTest
@testable import MessagesForAIMenu

/// Dev-only visual QA: rasterizes design surfaces to PNGs so the rendered result
/// can be eyeballed during the design-system refinement, instead of editing blind.
/// Gated behind `RENDER_SNAPSHOTS=1` so it never runs in normal `swift test`/CI.
/// Writes to `/tmp/mfa-snapshots/`. Not an assertion test — it's a render dump.
///
///   RENDER_SNAPSHOTS=1 swift test --filter DesignSnapshots
final class DesignSnapshots: XCTestCase {
  @MainActor
  func test_renderSurfaces() throws {
    guard ProcessInfo.processInfo.environment["RENDER_SNAPSHOTS"] == "1" else {
      throw XCTSkip("Set RENDER_SNAPSHOTS=1 to render design snapshots.")
    }

    let outDir = URL(fileURLWithPath: "/tmp/mfa-snapshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Throwaway settings home so nothing touches ~/.messages-mcp.
    let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("mfa-snap-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)

    let settings = SettingsStore(homeOverride: tmpHome)
    settings.firstRunComplete = false
    settings.imessageEnabled = true
    settings.whatsappEnabled = true
    let whatsapp = WhatsAppDaemonController()
    let imessage = IMessageDaemonController()

    for scheme in [ColorScheme.light, ColorScheme.dark] {
      let tag = scheme == .dark ? "dark" : "light"

      render(
        OnboardingView()
          .environmentObject(settings)
          .environmentObject(whatsapp),
        to: outDir.appendingPathComponent("onboarding-\(tag).png"),
        scheme: scheme,
        width: 460
      )

      render(
        SetupWalkthroughView()
          .environmentObject(settings)
          .environmentObject(whatsapp)
          .environmentObject(imessage)
          .frame(height: 640),
        to: outDir.appendingPathComponent("walkthrough-\(tag).png"),
        scheme: scheme,
        width: 560
      )

      // Safety callouts (no env deps) + the induced-draft warning.
      render(
        VStack(spacing: 12) {
          DSCalloutCard(severity: .info, title: "A new version is available.")
          DSCalloutCard(severity: .warning, title: "Sending is paused while we verify your account.")
          DSCalloutCard(severity: .critical, title: "Sending is disabled. Update Ghostie to continue.")
          InducedDraftBadge()
        },
        to: outDir.appendingPathComponent("callouts-\(tag).png"),
        scheme: scheme,
        width: 420
      )

      // Walkthrough install-summary states (can't render in-context — ScrollView
      // doesn't rasterize — so verify the standalone composition for all 3 states).
      render(
        VStack(spacing: 12) {
          ForEach([("ready", DSStatusDot.Status.ok, "Ghostie is ready", "Everything's installed and connected."),
                   ("checking", .pending, "Checking your setup…", "This only takes a moment."),
                   ("attention", .attention, "A couple things need your attention", "Open Setup details below to fix them.")], id: \.0) { _, status, title, detail in
            HStack(spacing: 12) {
              DSStatusDot(status: status, size: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.settingsTitle).foregroundStyle(DS.Color.ink(scheme))
                Text(detail).font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink3(scheme))
              }
              Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.g130(scheme)))
            .dsHairline(scheme, DS.Color.line, radius: 12)
          }
        },
        to: outDir.appendingPathComponent("install-summary-\(tag).png"),
        scheme: scheme,
        width: 520
      )

      // Stat-number tokens (the LABS big numbers) — verify the rounded, consumer
      // numeral look that replaced `design: .monospaced`.
      render(
        HStack(spacing: 12) {
          ForEach(["3.2h", "87%", "1,204"], id: \.self) { v in
            VStack(alignment: .leading, spacing: 6) {
              Text(v).font(DS.Font.statNumber).foregroundStyle(DS.Color.ink(scheme))
              Text("median reply").font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(scheme))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Color.g080(scheme)))
          }
        },
        to: outDir.appendingPathComponent("stats-\(tag).png"),
        scheme: scheme,
        width: 460
      )

      // DSButton kitchen-sink — the new button language in every variant/size/state.
      render(
        VStack(alignment: .leading, spacing: 18) {
          ForEach([("REGULAR", DSButtonSize.regular), ("SMALL", DSButtonSize.small)], id: \.0) { label, sz in
            VStack(alignment: .leading, spacing: 9) {
              Text(label).font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(scheme))
              HStack(spacing: 10) {
                Button("Primary") {}.dsButton(.primary, size: sz)
                Button("Secondary") {}.dsButton(.secondary, size: sz)
                Button("Ghost") {}.dsButton(.ghost, size: sz)
                Button { } label: { Label("Delete", systemImage: "trash") }.dsButton(.destructive, size: sz)
              }
            }
          }
          HStack(spacing: 10) {
            Button { } label: { Label("Send", systemImage: "paperplane.fill") }.dsButton(.primary)
            Button("Disabled") {}.dsButton(.primary).disabled(true)
            Button("Secondary disabled") {}.dsButton(.secondary).disabled(true)
          }
          // Icon-only DS buttons (toolbar affordances): square, no title.
          VStack(alignment: .leading, spacing: 9) {
            Text("ICON-ONLY").font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(scheme))
            HStack(spacing: 10) {
              Button { } label: { Image(systemName: "square.and.pencil") }.dsIconButton(.secondary)
              Button { } label: { Image(systemName: "chevron.left") }.dsIconButton(.secondary)
              Button { } label: { Image(systemName: "arrow.clockwise") }.dsIconButton(.ghost)
              Button { } label: { Image(systemName: "xmark") }.dsIconButton(.ghost, size: .small)
              Button { } label: { Image(systemName: "trash") }.dsIconButton(.destructive, size: .small)
            }
          }
          Button("Full-width primary") {}.dsButton(.primary, fullWidth: true)
        },
        to: outDir.appendingPathComponent("buttons-\(tag).png"),
        scheme: scheme,
        width: 540
      )

      // Layout primitives kitchen-sink — pane header, sections, form rows, cards,
      // pills, empty state composed together.
      render(
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
          DSPaneHeader("Settings", subtitle: "How Ghostie behaves.", systemImage: "gearshape") {
            Button("Done") {}.dsButton(.secondary, size: .small)
          }
          DSSection("Messaging") {
            VStack(spacing: 0) {
              DSFormRow("Require approval", subtitle: "Hold to send every draft.", systemImage: "checkmark.shield") {
                Text("On").font(DS.Font.settingsLabel).foregroundStyle(DS.Color.ink3(scheme))
              }
              Divider().overlay(DS.Color.line(scheme)).padding(.leading, 50)
              DSFormRow("Quiet hours", systemImage: "moon") {
                Text("10pm–8am").font(DS.Font.settingsLabel).foregroundStyle(DS.Color.ink3(scheme))
              }
            }
            .dsCard(scheme, variant: .plain)
          }
          HStack(spacing: 8) {
            DSPill("New")
            DSPill("Beta", systemImage: "flask", tint: DS.Color.blue)
            DSPill("Paused", tint: DS.Color.amber(scheme))
          }
          DSEmptyState(systemImage: "tray", title: "Nothing here yet", message: "Approved items will show up in this list.") {
            Button("Get started") {}.dsButton(.primary, size: .small)
          }
          .dsCard(scheme, variant: .raised)
        },
        to: outDir.appendingPathComponent("primitives-\(tag).png"),
        scheme: scheme,
        width: 560
      )
      // Messages tab — conversation list fixtures (priority queue, unread dot,
      // previews, group row, birthday nudge) + a transcript composition
      // (date separator, bubbles, attachment chip, read receipt).
      let avatars = ContactAvatarStore()
      render(
        VStack(alignment: .leading, spacing: 2) {
          BirthdayNudgeRow(
            birthday: snapshotBirthday,
            onOpen: {},
            onDismiss: {}
          )
          .padding(.bottom, 8)
          Text("PRIORITY").font(DS.Font.sectionLabel).tracking(0.6).foregroundStyle(DS.Color.ink3(scheme))
            .padding(.horizontal, 10).padding(.bottom, 6)
          MessageConversationRow(
            conversation: snapshotConversation(
              id: 1, title: "Maya Chen", preview: "can you send the doc before lunch?", unread: 2
            ),
            selected: true,
            isUnread: true,
            label: nil,
            priority: ThreadPriorityEntry(level: 1, reason: "deadline today", setAt: nil, setBy: "agent")
          )
          MessageConversationRow(
            conversation: snapshotConversation(
              id: 2, title: "Dad", preview: "Loved a message"
            ),
            selected: false,
            label: nil,
            priority: ThreadPriorityEntry(level: 2, reason: nil, setAt: nil, setBy: "agent")
          )
          Text("RECENT").font(DS.Font.sectionLabel).tracking(0.6).foregroundStyle(DS.Color.ink3(scheme))
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 6)
          MessageConversationRow(
            conversation: snapshotConversation(
              id: 3, title: "Ski Trip 2026", preview: "Attachment", isGroup: true, subtitle: "5 people"
            ),
            selected: false,
            label: nil,
            priority: nil
          )
          MessageConversationRow(
            conversation: snapshotConversation(
              id: 4, title: "Sam Rivera", preview: "see you there!", platform: .whatsapp
            ),
            selected: false,
            label: nil,
            priority: nil
          )
        }
        .environmentObject(avatars),
        to: outDir.appendingPathComponent("messages-list-\(tag).png"),
        scheme: scheme,
        width: 360
      )

      render(
        VStack(alignment: .leading, spacing: 7) {
          TranscriptDateSeparator(date: Date(timeIntervalSinceNow: -90_000))
          ContextBubbleView(
            message: snapshotMessage(body: "Are we still on for tonight?", fromMe: false),
            showSender: false, platform: .imessage, showTimestamp: false
          )
          ContextBubbleView(
            message: snapshotMessage(body: "Yes! 7pm at the usual spot", fromMe: true),
            showSender: false, platform: .imessage, showTimestamp: false
          )
          TranscriptDateSeparator(date: Date())
          ContextBubbleView(
            message: snapshotMessage(
              body: nil, fromMe: false,
              attachments: [MessageAttachmentRef(path: nil, mimeType: "application/pdf", name: "itinerary.pdf", byteCount: 482_000)]
            ),
            showSender: false, platform: .imessage, showTimestamp: false
          )
          ContextBubbleView(
            message: snapshotMessage(body: "perfect, got it", fromMe: true),
            showSender: false, platform: .imessage, showTimestamp: false,
            receipt: .text("Read 2:14 PM")
          )
        },
        to: outDir.appendingPathComponent("messages-transcript-\(tag).png"),
        scheme: scheme,
        width: 480
      )
    }

    print("[snapshots] wrote PNGs to \(outDir.path)")
  }

  private var snapshotBirthday: UpcomingBirthday {
    UpcomingBirthday(
      name: "Maya", birthday: "06-10", nextOccurrence: "2026-06-10", daysUntil: 0,
      weekday: "Wednesday", ageTurning: 31, relationship: "friend", notes: nil,
      bestHandle: "+14045550100", handles: ["+14045550100"], source: "manual",
      pinned: false, muted: false, outCount: 200, textRank: 1, callCount: 4,
      callRank: nil, wishedBefore: true, wishedYears: [2025], suggested: true,
      reasons: [], suggestedMessage: ""
    )
  }

  private func snapshotConversation(
    id: Int,
    title: String,
    preview: String,
    unread: Int = 0,
    isGroup: Bool = false,
    subtitle: String = "",
    platform: Platform = .imessage
  ) -> MessageConversation {
    var recent = RecentComposeThread(
      id: "\(platform.rawValue)-\(id)",
      platform: platform,
      handle: platform == .whatsapp ? "1404555010\(id)@s.whatsapp.net" : "+1404555010\(id)",
      title: title,
      subtitle: subtitle,
      threadID: id,
      lastMessageDate: Date(timeIntervalSinceNow: -Double(id) * 4_000),
      unreadCount: unread,
      isGroup: isGroup
    )
    recent.lastMessagePreview = preview
    return MessageConversation(recent: recent, draftThread: nil)
  }

  private func snapshotMessage(
    body: String?,
    fromMe: Bool,
    attachments: [MessageAttachmentRef] = []
  ) -> ContextMessage {
    var message = ContextMessage(
      guid: UUID().uuidString,
      from_me: fromMe,
      sender_handle: fromMe ? nil : "+14045550100",
      sender_name: fromMe ? nil : "Maya Chen",
      body: body,
      sent_at: "2026-06-10T14:02:00.000Z"
    )
    message.attachments = attachments
    return message
  }

  @MainActor
  private func render<V: View>(_ view: V, to url: URL, scheme: ColorScheme, width: CGFloat) {
    // Window-like canvas so the elevation shadows actually read against a surface.
    let canvas = scheme == .dark
      ? Color(.sRGB, red: 0x17 / 255, green: 0x1B / 255, blue: 0x1F / 255, opacity: 1)
      : Color(.sRGB, red: 0xEC / 255, green: 0xEC / 255, blue: 0xEE / 255, opacity: 1)

    let content = view
      .environment(\.colorScheme, scheme)
      .frame(width: width)
      .padding(24)
      .background(canvas)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
      print("[snapshots] FAILED to render \(url.lastPathComponent)")
      return
    }
    try? png.write(to: url)
  }
}
