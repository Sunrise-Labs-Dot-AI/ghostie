import SwiftUI
import AppKit

/// The premium strip under the full-bleed Wrapped story: four model-written
/// insight slots (voice signature, ghosting profile, vibe, severance score),
/// each teeing up the lab that goes deeper. Gated by PremiumGate exactly like
/// the locked labs in ConsoleView, with the locked copy chosen by
/// LockedLabCopy (premium-messaging flag + PremiumFlags.subscriptionsLive).
/// Results come from DeepReadController's disk cache; only Run/Regenerate
/// spends tokens.
///
/// THEME: the Wrapped sunrise system (see WrappedToolView). The kit below is
/// file-private — a deliberate sibling of WrappedToolView's, not DS.
struct WrappedDeepReadPanel: View {
  @ObservedObject var controller: DeepReadController

  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var settingsFocus: SettingsFocusController
  @EnvironmentObject private var settings: SettingsStore
  @EnvironmentObject private var entitlements: EntitlementStore
  @EnvironmentObject private var textingVoice: TextingVoiceController
  @EnvironmentObject private var featureFlags: FeatureFlagStore
  @AppStorage("wrapped.deepRead.expanded") private var expanded = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let privacyNote =
    "Aggregate stats + message metadata only — message bodies never leave your Mac."

  private var unlocked: Bool {
    PremiumGate.unlocked(
      subscriptionActive: entitlements.subscriptionActive,
      hasAPIKey: textingVoice.hasAnyAPIKey
    )
  }

  /// Same copy policy as DisabledLabView; premium-messaging off = pure BYOK
  /// pitch, no "Premium — coming soon".
  private var lockedCopy: LockedLabCopy {
    LockedLabCopy.select(
      lead: "Deep Read uses AI on your aggregate stats",
      premiumMessagingEnabled: featureFlags.resolved(.premiumMessaging),
      subscriptionsLive: PremiumFlags.subscriptionsLive
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(Color.white.opacity(0.10))
        .frame(height: 1)
      header
      if expanded {
        content
          .padding(.horizontal, 16)
          .padding(.bottom, 14)
      }
    }
    .frame(maxWidth: .infinity)
    .background(Palette.bg)
  }

  // MARK: - Header

  private var header: some View {
    Button {
      withAnimation(DS.motion(reduceMotion, .easeInOut(duration: 0.16))) {
        expanded.toggle()
      }
    } label: {
      HStack(spacing: 10) {
        Text("deep read")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .tracking(1.4)
          .textCase(.uppercase)
          .foregroundStyle(Palette.accent)
        Text("What the numbers say about you.")
          .font(.system(size: 13, weight: .regular, design: .serif).italic())
          .foregroundStyle(Palette.paper)
        if !unlocked {
          Label(
            featureFlags.resolved(.premiumMessaging)
              ? (PremiumFlags.subscriptionsLive ? "Premium" : "Premium — coming soon")
              : "Bring your own key",
            systemImage: lockedCopy.badgeSystemImage
          )
          .font(.system(size: 9.5, weight: .heavy))
          .foregroundStyle(Palette.bg)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(Palette.accent))
        }
        Spacer(minLength: 0)
        if expanded, unlocked, case .ready(let insights) = controller.state {
          Text("read \(Self.relativeLabel(insights.generatedAt))")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.soft)
          regenerateButton
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Palette.soft)
          .rotationEffect(.degrees(expanded ? 0 : 180))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Deep Read")
    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
  }

  private var regenerateButton: some View {
    Button {
      controller.generate(force: true)
    } label: {
      Label("Regenerate", systemImage: "arrow.clockwise")
        .font(.system(size: 10, weight: .heavy))
    }
    .buttonStyle(LinkButtonStyle())
    .disabled(controller.isBusy)
    .accessibilityLabel("Regenerate Deep Read")
  }

  // MARK: - Content states

  @ViewBuilder
  private var content: some View {
    if !unlocked {
      locked
    } else {
      switch controller.state {
      case .idle:
        empty
      case .loading(let message):
        loading(message)
      case .failed(let reason):
        failed(reason)
      case .ready(let insights):
        ready(insights)
      }
    }
  }

  /// Mirrors DisabledLabView's gate semantics on the sunrise surface.
  private var locked: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Four AI reads of your year: your texting voice's signature, your ghosting profile, your vibe, and whether you're severed.")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Palette.paper)
          .fixedSize(horizontal: false, vertical: true)
        Text(lockedCopy.body)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Palette.soft)
          .fixedSize(horizontal: false, vertical: true)
        privacyLine
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 8) {
        if lockedCopy.showsSubscribe {
          Button {
            if let url = URL(string: "https://messagesfor.ai/account.html") {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Label("Subscribe", systemImage: "person.crop.circle.badge.checkmark")
          }
          .buttonStyle(PillButtonStyle(prominent: true))
          Button {
            openAISettings()
          } label: {
            Label("Use my own key", systemImage: "key")
          }
          .buttonStyle(PillButtonStyle(prominent: false))
        } else {
          Button {
            openAISettings()
          } label: {
            Label("Add my API key", systemImage: "key")
          }
          .buttonStyle(PillButtonStyle(prominent: true))
        }
      }
    }
    .padding(.top, 2)
  }

  private var empty: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("The story above is deterministic math. This part actually reasons: your voice's signature, your ghosting profile, your vibe, your severance score.")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Palette.paper)
          .fixedSize(horizontal: false, vertical: true)
        if let selection = LabModelPreferences.clientSelection(for: .deepRead) {
          Text(AIUsageEstimate.label(for: .deepRead, provider: selection.provider, modelID: selection.modelID))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.soft)
        }
        privacyLine
      }
      Spacer(minLength: 12)
      Button {
        controller.generate()
      } label: {
        Label("Run Deep Read", systemImage: "sparkles")
      }
      .buttonStyle(PillButtonStyle(prominent: true))
      .accessibilityLabel("Run Deep Read")
    }
    .padding(.top, 2)
  }

  private func loading(_ message: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .environment(\.colorScheme, .dark) // spinner must read on the dark panel
      Text(message)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.paper)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
  }

  private func failed(_ reason: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(reason)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.paper)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      Button("Try again") {
        controller.generate(force: true)
      }
      .buttonStyle(PillButtonStyle(prominent: true))
    }
    .padding(.vertical, 6)
  }

  private func ready(_ insights: DeepReadInsights) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        voiceCard(insights.voice)
        ghostingCard(insights.ghosting)
        vibeCard(insights.vibe)
        severanceCard(insights.severance)
      }
      privacyLine
    }
  }

  // MARK: - Insight slots

  private func voiceCard(_ voice: DeepReadInsights.Voice) -> some View {
    insightCard(kicker: "voice signature") {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(voice.traits.prefix(3).enumerated()), id: \.offset) { _, trait in
          Text(trait)
            .font(.system(size: 13, weight: .regular, design: .serif).italic())
            .foregroundStyle(Palette.paper)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        if !voice.summary.isEmpty {
          Text(voice.summary)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.soft)
            .lineLimit(3)
        }
      }
    } teeUp: {
      teeUpLink("Build your Style", item: .textingVoice)
    }
  }

  private func ghostingCard(_ ghosting: DeepReadInsights.Ghosting) -> some View {
    insightCard(kicker: "ghosting profile") {
      VStack(alignment: .leading, spacing: 4) {
        Text(ghosting.headline)
          .font(.system(size: 13, weight: .regular, design: .serif).italic())
          .foregroundStyle(Palette.paper)
          .lineLimit(2)
          .minimumScaleFactor(0.85)
        if !ghosting.roast.isEmpty {
          Text(ghosting.roast)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.soft)
            .lineLimit(3)
        }
      }
    } teeUp: {
      teeUpLink("Open Don't Ghost", item: .tool("dontGhost"))
    }
  }

  private func vibeCard(_ vibe: DeepReadInsights.Vibe) -> some View {
    insightCard(kicker: "your vibe") {
      VStack(alignment: .leading, spacing: 4) {
        Text(vibe.archetype)
          .font(.system(size: 15, weight: .regular, design: .serif).italic())
          .foregroundStyle(Palette.accent)
          .lineLimit(2)
          .minimumScaleFactor(0.85)
        if !vibe.evidence.isEmpty {
          Text(vibe.evidence)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.soft)
            .lineLimit(3)
        }
      }
    } teeUp: {
      teeUpLink("Explore Texting Analytics", item: .tool("textingAnalytics"))
    }
  }

  private func severanceCard(_ severance: DeepReadInsights.Severance) -> some View {
    insightCard(kicker: "are you severed?") {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text("\(severance.score)")
            .font(.system(size: 26, weight: .regular, design: .serif).italic())
            .foregroundStyle(Palette.paper)
          Text("/ 100")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.soft)
        }
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
            Capsule()
              .fill(Palette.accent)
              .frame(width: proxy.size.width * CGFloat(severance.score) / 100)
          }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
        if !severance.oneLiner.isEmpty {
          Text(severance.oneLiner)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.soft)
            .lineLimit(3)
        }
      }
    } teeUp: {
      teeUpLink("Try Severance", item: .tool("workPersonal"))
    }
    .accessibilityLabel("Severance score \(severance.score) out of 100")
  }

  private func insightCard<Content: View, TeeUp: View>(
    kicker: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder teeUp: () -> TeeUp
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(kicker)
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .tracking(1.1)
        .textCase(.uppercase)
        .foregroundStyle(Palette.soft)
      content()
      Spacer(minLength: 0)
      teeUp()
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
    )
  }

  /// Tee-up into the lab that goes deeper. Hidden in Wrapped-only mode,
  /// where those panes aren't reachable (ConsoleView would bounce back).
  @ViewBuilder
  private func teeUpLink(_ title: String, item: ConsoleItem) -> some View {
    if !settings.isTextingWrappedOnly {
      Button {
        nav.selection = item
      } label: {
        HStack(spacing: 4) {
          Text(title)
          Image(systemName: "arrow.right")
        }
        .font(.system(size: 10, weight: .heavy))
      }
      .buttonStyle(LinkButtonStyle())
      .accessibilityLabel(title)
    }
  }

  private var privacyLine: some View {
    Text(Self.privacyNote)
      .font(.system(size: 9, weight: .medium, design: .monospaced))
      .foregroundStyle(Palette.soft.opacity(0.9))
      .fixedSize(horizontal: false, vertical: true)
  }

  private func openAISettings() {
    settingsFocus.target = .ai
    nav.selection = .settings
  }

  private static func relativeLabel(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - File-private sunrise kit (panel-side)

private enum Palette {
  /// The strip under the story — darker than the card plum so the story
  /// keeps visual priority.
  static let bg = Color(red: 0.07, green: 0.025, blue: 0.055)
  static let card = Color(red: 0.115, green: 0.05, blue: 0.095)
  static let paper = Color(red: 1.0, green: 0.93, blue: 0.88)
  static let soft = Color(red: 1.0, green: 0.93, blue: 0.88).opacity(0.55)
  static let accent = Color(red: 1.0, green: 0.55, blue: 0.35)
}

private struct PillButtonStyle: ButtonStyle {
  var prominent: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    return configuration.label
      .font(.system(size: 11, weight: .heavy))
      .lineLimit(1)
      .padding(.horizontal, 13)
      .frame(height: 28)
      .foregroundStyle(prominent ? Color(red: 0.10, green: 0.04, blue: 0.08) : Palette.paper)
      .background(
        Capsule().fill(prominent ? Palette.accent : Color.white.opacity(0.10))
      )
      .overlay(
        Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.22), lineWidth: 1)
      )
      .offset(y: pressed ? 1 : 0)
      .opacity(isEnabled ? (pressed ? 0.9 : 1) : 0.45)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
  }
}

private struct LinkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Palette.accent.opacity(configuration.isPressed ? 0.7 : 1))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }
}
