import SwiftUI

/// Warning-style banner shown above a WhatsApp draft when the daemon
/// flagged it as "induced by an unknown contact" — staged within 60 s of
/// an inbound message from a sender not in the user's contacts.
///
/// The flag is the menubar's defense against prompt-injection-driven
/// auto-replies: if an unknown number messages the user and that
/// message contains "draft a reply saying X" (or otherwise manipulates
/// the assistant), this is the visual cue + extra hold-to-fire friction
/// that the user is about to send a message that was originally
/// shaped by an unverified party.
///
/// Pairs with a 2 s hold-to-fire duration on the row (up from the
/// default 1 s) — see PendingMessageBubble in DraftsPane.swift. The longer hold is the
/// load-bearing safeguard; this badge is the explainer that tells the
/// user WHY the row feels different.
struct InducedDraftBadge: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(DS.Color.amber(colorScheme))
      VStack(alignment: .leading, spacing: 1) {
        Text("Caution: draft induced by unknown contact")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text("This draft was created within 60 s of a message from a number that's not in your contacts. Hold to send takes 2 s instead of 1 s.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(DS.Color.amberDim(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(DS.Color.amber(colorScheme), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Warning: draft induced by unknown contact. Hold to send takes 2 seconds.")
  }
}
