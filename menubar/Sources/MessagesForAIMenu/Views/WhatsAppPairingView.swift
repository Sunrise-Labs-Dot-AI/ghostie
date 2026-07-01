import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// First-time pairing sheet for the WhatsApp daemon. Opens a streaming
/// JSON-RPC `subscribe("qr")` session against `~/.whatsapp-mcp/
/// daemon.sock`, renders pushed QR codes for the user to scan with
/// WhatsApp on their phone (Settings → Linked Devices → Link a Device),
/// and auto-dismisses when the daemon reports `state: "connected"`.
///
/// State machine:
/// ```
/// .checkingSentinel  ─── if LOGGED_OUT sentinel exists ──→ .loggedOutRecovery
///         │
///         ↓ (no sentinel)
///   .awaitingUserReady  ── user taps "Ready to scan" ──→ .startingDaemon
///         │                              (or straight to .subscribing if the
///         │                               daemon is already running)
///         ↓
///   .subscribing  ── daemon error / not running ──→ .error(...)
///         │
///         ↓ (subscribed)
///   .awaitingFirstQR
///         │
///         ↓ (qr.update)
///   .awaitingScan(qr) ←─── qr.update (re-issued every ~20s by WhatsApp)
///         │
///         ↓ (state.update: connecting)
///   .pairingHandshake
///         │
///         ↓ (state.update: connected)
///   .connected → sheet auto-dismisses after a brief success state
/// ```
///
/// The loggedOutRecovery branch presents a confirmation + invokes
/// `unlinkAndReset` then drops back to `.subscribing` for a fresh pair.
struct WhatsAppPairingView: View {
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @EnvironmentObject var settings: SettingsStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow

  @State private var phase: Phase = .checkingSentinel
  /// Time at which the currently-displayed QR expires. Drives the
  /// countdown bar. The daemon pushes a fresh QR every ~20 s; we reset
  /// this clock on every `qr.update`.
  @State private var qrExpiresAt: Date = .distantPast
  /// True while the unlinkAndReset confirmation alert is shown.
  @State private var confirmReset: Bool = false
  /// Drives the countdown bar's progress fill. Refreshed by a SwiftUI
  /// timer publisher — see `body`.
  @State private var now: Date = Date()
  private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
  /// Rendered QR image, cached so the 0.2s countdown re-render doesn't re-run
  /// the CIFilter + rasterize pipeline 5×/sec for an unchanged code. Set only
  /// when the daemon pushes a new QR (the `.qrUpdate` event).
  @State private var qrImage: Image?

  enum Phase: Equatable {
    case checkingSentinel
    case loggedOutRecovery
    /// One-time risk acknowledgement before linking via the unofficial
    /// WhatsApp client. Kept separate from the ready gate so no daemon or QR
    /// work starts until the user explicitly accepts the risk.
    case riskAcknowledgment
    /// Pre-pairing gate. We show the user how to reach Link a Device on
    /// their phone and wait for an explicit "Ready to scan" tap before
    /// touching the daemon — so the ~20s QR-rotation clock (enforced by
    /// WhatsApp's protocol, not us) only starts once the phone camera is
    /// already aimed at the screen.
    case awaitingUserReady
    /// Daemon isn't running yet; we kicked .start() and are waiting for
    /// the controller to flip to .running before subscribing.
    case startingDaemon
    case subscribing
    case awaitingFirstQR
    case awaitingScan(qr: String)
    case pairingHandshake
    case connected
    case error(String)
  }

  var body: some View {
    // Native macOS title bar (set in App.swift) provides chrome +
    // traffic-light close — no in-content header needed.
    VStack(spacing: 16) {
      content
      Spacer()
      footer
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      if WhatsAppQRSession.loggedOutSentinelExists {
        // Remote logout recovery is its own flow (wipe + re-pair) and
        // keeps its existing UX — no Ready gate. Re-pairing implies the user
        // already accepted the linking risk on the first pair.
        phase = .loggedOutRecovery
      } else if !settings.whatsappRiskAcknowledged {
        // Require the one-time linking-risk acknowledgment before anything
        // touches the daemon or starts a QR. Gates every pairing entry path
        // (onboarding, Settings) since they all land here.
        phase = .riskAcknowledgment
      } else {
        // Don't start the daemon or request a QR yet. Show the Ready gate
        // first so the user has time to open Link a Device on their phone
        // before the QR-rotation clock starts. Closing the window from
        // here leaves no daemon started by this view.
        phase = .awaitingUserReady
      }
    }
    .onChange(of: whatsappDaemon.status) { _, status in
      // While we're waiting for the service to come up, watch the
      // controller's status. The .startingDaemon → .subscribing
      // transition fires once on the first .running observation.
      guard case .startingDaemon = phase else { return }
      switch status {
      case .running:
        phase = .subscribing
      case .crashLooping:
        phase = .error("WhatsApp couldn't connect after several tries. Open Settings and toggle WhatsApp off, then back on, to try a fresh pair.")
      default:
        break
      }
    }
    .task(id: shouldRunSubscription) {
      // The .task(id:) modifier restarts the task whenever the id
      // changes. We use that to (re-)start the subscription:
      //  - on initial appear when phase = .subscribing
      //  - again after the user completes unlinkAndReset
      guard shouldRunSubscription else { return }
      await runSubscription()
    }
    .onReceive(timer) { t in
      now = t
    }
    .alert("Wipe local WhatsApp session?", isPresented: $confirmReset) {
      Button("Cancel", role: .cancel) {}
      Button("Reconnect", role: .destructive) {
        Task { await runUnlinkAndReset() }
      }
    } message: {
      Text("This deletes the encrypted session credential at ~/.whatsapp-mcp/session.db so the daemon can re-pair from scratch. Your message history (~/.whatsapp-mcp/messages.db) is preserved.")
    }
  }

  /// Whether the .task should be running the subscribe loop. Computed
  /// from phase so transitions naturally start/stop the task.
  private var shouldRunSubscription: Bool {
    switch phase {
    case .subscribing, .awaitingFirstQR, .awaitingScan, .pairingHandshake:
      return true
    default:
      return false
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .checkingSentinel:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loggedOutRecovery:
      loggedOutView
    case .riskAcknowledgment:
      riskAcknowledgmentView
    case .awaitingUserReady:
      awaitingUserReadyView
    case .startingDaemon:
      startingDaemonView
    case .subscribing, .awaitingFirstQR:
      waitingForQR
    case .awaitingScan(let qr):
      qrCodeView(qr: qr)
    case .pairingHandshake:
      pairingHandshakeView
    case .connected:
      connectedView
    case .error(let message):
      errorView(message)
    }
  }

  /// One-time linking-risk acknowledgment. Gates the entire pairing flow:
  /// until the user accepts, nothing here touches the daemon or starts a QR.
  /// Confirming records `settings.whatsappRiskAcknowledged` so it's never
  /// shown again, then advances to the Ready gate.
  private var riskAcknowledgmentView: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(DS.Color.amber(colorScheme))
        VStack(alignment: .leading, spacing: 6) {
          Text("Before you link WhatsApp")
            .font(DS.Font.settingsTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("Linking WhatsApp uses Baileys, an unofficial WhatsApp client. WhatsApp's Terms don't sanction third-party clients, so your number could be flagged or banned. You can use iMessage without WhatsApp.")
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink2(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12)
      .dsCard(colorScheme, fill: DS.Color.amberDim(colorScheme), radius: DS.Radius.card)

      Button("I understand and accept this risk") {
        settings.acknowledgeWhatsAppRisk()
        // Advance to the existing Ready gate; the daemon still isn't
        // touched until the user taps "Ready to scan".
        phase = .awaitingUserReady
      }
      .dsButton(.primary, fullWidth: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Pre-pairing instructions + the "Ready to scan" gate. Nothing here
  /// touches the daemon — see `beginPairing()`.
  private var awaitingUserReadyView: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Link WhatsApp to this Mac")
          .font(DS.Font.settingsTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text("You'll scan a QR code with your phone. It refreshes about every 20 seconds, so get your phone ready first — then tap Ready to scan.")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink2(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 8) {
        readyStep(1, "Open **WhatsApp** on your phone")
        readyStep(2, "Tap **Settings** (bottom-right on iPhone, or the **⋮** menu on Android)")
        readyStep(3, "Tap **Linked Devices**")
        readyStep(4, "Tap **Link a Device** and authenticate")
        readyStep(5, "Point your phone's camera at this window")
      }

      Button("Ready to scan") {
        beginPairing()
      }
      .dsButton(.primary, fullWidth: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readyStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(number).")
        .font(DS.Font.monoValue.weight(.semibold))
        .foregroundStyle(Platform.whatsapp.accentColor)
        .frame(width: 20, alignment: .trailing)
      Text(text)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    // Combine the number and instruction so VoiceOver reads "Open WhatsApp on
    // your phone" as one element, not a bare "1." followed by the text.
    .accessibilityElement(children: .combine)
  }

  private var startingDaemonView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Starting WhatsApp…")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// True if the daemon's WhatsAppDaemonController already considers it
  /// running. Avoids the brief "Starting…" flash when the user re-opens
  /// the pairing sheet on an already-paired session.
  private var isDaemonAlreadyRunning: Bool {
    if case .running = whatsappDaemon.status { return true }
    return false
  }

  /// Leave the Ready gate and enter the existing pairing flow. Mirrors the
  /// pre-#18 onAppear logic exactly, so tapping Ready quickly hits the same
  /// code path it always did (.subscribing if the daemon is already up,
  /// otherwise start it and wait in .startingDaemon).
  private func beginPairing() {
    if isDaemonAlreadyRunning {
      phase = .subscribing
    } else {
      whatsappDaemon.start()
      phase = .startingDaemon
    }
  }

  @ViewBuilder
  private var footer: some View {
    Group {
      switch phase {
      case .awaitingScan:
        Text("Open WhatsApp on your phone → Settings → Linked Devices → Link a Device, then scan this QR.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .multilineTextAlignment(.center)
      case .error:
        // No footer help — error view handles its own messaging.
        EmptyView()
      default:
        EmptyView()
      }
    }
  }

  // MARK: - Phase views

  private var waitingForQR: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Generating pairing code…")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func qrCodeView(qr: String) -> some View {
    VStack(spacing: 12) {
      // Use the cached image; fall back to an inline render if somehow unset.
      if let image = qrImage ?? Self.renderQR(qr) {
        image
          .interpolation(.none)  // crisp pixel edges, no blur
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
          .accessibilityLabel("WhatsApp pairing QR code")
      } else {
        Text("Failed to render QR code")
          .foregroundStyle(DS.Color.red)
      }
      // Countdown bar — WhatsApp re-issues the QR every ~20 s, and
      // the daemon pushes the fresh one. This bar resets on every
      // qrUpdate event (we reset qrExpiresAt in handle()).
      ProgressView(value: countdownProgress)
        .progressViewStyle(.linear)
        .frame(width: 220)
        .tint(Platform.whatsapp.accentColor)
        // Unlabeled, the countdown bar is silent (or a bare "%") to VoiceOver;
        // a screen-reader user has no idea the code is about to expire.
        .accessibilityLabel("Pairing code expires in")
        .accessibilityValue("\(Int((countdownProgress * 20).rounded())) seconds")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var pairingHandshakeView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Phone scanned. Finishing pairing…")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var connectedView: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(Platform.whatsapp.accentColor)
      Text("Connected")
        .font(DS.Font.settingsTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("WhatsApp is paired. This window closes in a moment.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      // Pairing used to chain into the setup walkthrough here. It no longer
      // does: the walkthrough verifies the Claude/MCP wiring — an AI step
      // that stays out of onboarding. It remains available on demand from
      // Settings → Advanced → Status for anyone wiring up the AI loop.
      dismissWindow(id: WindowID.whatsappPairing)
    }
  }

  private var loggedOutView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(DS.Color.amber(colorScheme))
      Text("Disconnected")
        .font(DS.Font.settingsTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("WhatsApp logged this device out remotely (or the daemon hit a logged_out signal). To re-pair, the local session credential must be wiped first.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Reconnect…") {
        confirmReset = true
      }
      .dsButton(.primary)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "xmark.octagon.fill")
        .font(.system(size: 40))
        .foregroundStyle(DS.Color.red)
      Text("Couldn't connect")
        .font(DS.Font.settingsTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text(message)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Retry") {
        phase = .subscribing
      }
      .dsButton(.primary)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Subscription logic

  private func runSubscription() async {
    let session = WhatsAppQRSession()
    for await event in session.eventStream() {
      // The view may transition into a non-subscription phase (error,
      // connected) — that flips shouldRunSubscription false, the
      // .task(id:) modifier cancels this for-await, and we exit.
      switch event {
      case .subscribed:
        if case .subscribing = phase {
          phase = .awaitingFirstQR
        }
      case .qrUpdate(let qr):
        // Render once here — off the 0.2s countdown re-render path — so the
        // expensive CIFilter pipeline runs per new QR, not 5×/sec.
        qrImage = Self.renderQR(qr)
        phase = .awaitingScan(qr: qr)
        // WhatsApp QRs are valid for ~20 s. The daemon will push a
        // fresh one before this expires; we reset the bar on each
        // update.
        qrExpiresAt = Date().addingTimeInterval(20.0)
      case .stateUpdate(let state):
        // The daemon emits "connecting" (Baileys is shaking hands)
        // then "connected" (paired + auth complete). We treat any
        // post-QR state transition that isn't "connecting" as a
        // signal to leave the QR view.
        if state == "connected" {
          phase = .connected
          return
        }
        if state == "connecting" {
          phase = .pairingHandshake
        }
      case .closed:
        if phase != .connected {
          phase = .error("Couldn't reach WhatsApp. The connection dropped before pairing completed. Try Retry, or quit and reopen Ghostie if it keeps failing.")
        }
        return
      case .error(let message):
        phase = .error(message)
        return
      }
    }
  }

  private func runUnlinkAndReset() async {
    do {
      try await WhatsAppRPCClient.unlinkAndReset()
      // Daemon clears the sentinel + deletes session.db. Transition
      // back to subscribing — the .task(id:) modifier will fire again.
      phase = .subscribing
    } catch {
      phase = .error("Reconnect failed: \(error.localizedDescription)")
    }
  }

  // MARK: - QR rendering

  /// Convert the daemon-supplied WhatsApp pairing string into a
  /// renderable SwiftUI `Image`. Uses Core Image's
  /// `CIQRCodeGenerator`, rendered at native scale and then upscaled
  /// with `.none` interpolation in the view for crisp pixels.
  /// Shared CIContext — constructing one allocates a CPU/GPU render pipeline,
  /// so reuse a single instance rather than building one on every call.
  private static let ciContext = CIContext()

  private static func renderQR(_ payload: String) -> Image? {
    let ctx = Self.ciContext
    guard let data = payload.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let raw = filter.outputImage else { return nil }
    // Upscale ~10x so the cgImage rasterizes at a usable resolution
    // before SwiftUI's view-side scale.
    let scaled = raw.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
    let ns = NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    return Image(nsImage: ns)
  }

  /// Linear interpolation from 1.0 (just refreshed) → 0.0 (expired).
  private var countdownProgress: Double {
    let total = 20.0
    let remaining = max(0, qrExpiresAt.timeIntervalSince(now))
    return min(1.0, remaining / total)
  }
}
