import AppKit
import SwiftUI

struct RemoteHostingSettingsSection: View {
  @ObservedObject private var remote = RemoteHostingController.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Host a remote MCP", systemImage: "network").font(.headline)
      Text("Connect an AI client to iMessage and WhatsApp on this Mac. It can read messages and stage text drafts for your review in Ghostie.").font(.callout)
      Text("This Mac must stay awake with Ghostie running. If the app quits, the Mac sleeps, or the connection drops, the MCP is unavailable.").font(.caption).foregroundStyle(.secondary)
      if let account = remote.account {
        Text("Account: \(account.user)").font(.caption).textSelection(.enabled)
        HStack {
          Button(remote.isHosting ? "Stop hosting" : "Start hosting") {
            if remote.isHosting { remote.stopHosting() } else { remote.startHosting() }
          }
          Button("Copy MCP URL") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.mcpURL, forType: .string)
          }
          Button("Disconnect account") { remote.disconnectAccount() }
        }.disabled(remote.isDisconnecting)
      } else {
        TextField("Ghostie service URL", text: $remote.relayOrigin, prompt: Text("HTTPS service URL"))
          .textFieldStyle(.roundedBorder).disabled(remote.isPairing)
        Text("Use the Ghostie service address supplied with your build. Accounts are managed by Clerk.").font(.caption).foregroundStyle(.secondary)
        if let code = remote.pairingCode {
          Text(code).font(.title2.monospaced()).textSelection(.enabled).accessibilityLabel("Pairing code \(code)")
          if let url = remote.pairingURL { Link("Continue in browser", destination: url) }
        }
        HStack {
          Button("Create account or sign in") { remote.createAccountOrSignIn() }
            .disabled(remote.isPairing || RemoteHostingPolicy.origin(remote.relayOrigin) == nil)
          if remote.isPairing { Button("Cancel") { remote.cancelPairing() } }
        }
      }
      Text(remote.status).font(.callout).accessibilityLabel("Remote hosting status: \(remote.status)")
      Text("Connections use HTTPS encryption. The relay can see content in memory; it does not store messages. Credentials stay in Keychain. Suspected 2FA codes and sign-in links are hidden on this Mac before results leave it. Filtering may miss unfamiliar formats. Local messages and drafts retain their existing storage protection.").font(.caption).foregroundStyle(.secondary)
      Text("Remote access cannot send, approve, schedule, or attach local files. Review every remotely staged draft before sending.").font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 8)
  }
}
