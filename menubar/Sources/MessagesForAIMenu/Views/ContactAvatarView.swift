import SwiftUI

/// Messages.app-style circular avatar: contact photo when the Contacts
/// database has one, otherwise white initials on a soft gray gradient (the
/// native monogram look). Groups get the group glyph. WhatsApp conversations
/// carry a small platform badge so the merged list stays scannable.
struct ContactAvatarView: View {
  let handle: String
  let title: String
  let isGroup: Bool
  let platform: Platform
  var size: CGFloat = 34

  @EnvironmentObject private var avatars: ContactAvatarStore
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      if !isGroup, let image = avatars.avatar(for: handle) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else {
        Circle()
          .fill(monogramGradient)
        if isGroup {
          Image(systemName: "person.2.fill")
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(.white)
        } else {
          Text(monogram)
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(.white)
        }
      }
    }
    .frame(width: size, height: size)
    .overlay(
      Circle().strokeBorder(DS.Color.line(colorScheme), lineWidth: 0.5)
    )
    .overlay(alignment: .bottomTrailing) {
      if platform == .whatsapp {
        platformBadge
      }
    }
    .accessibilityHidden(true)
  }

  /// The native monogram gradient — a quiet steel gray, light-on-top.
  private var monogramGradient: LinearGradient {
    let top = colorScheme == .dark
      ? Color(red: 0.46, green: 0.49, blue: 0.53)
      : Color(red: 0.71, green: 0.74, blue: 0.78)
    let bottom = colorScheme == .dark
      ? Color(red: 0.36, green: 0.39, blue: 0.43)
      : Color(red: 0.56, green: 0.60, blue: 0.65)
    return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
  }

  private var monogram: String {
    let parts = title
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .compactMap { $0.first }
    let initials = parts.prefix(2).map { String($0).uppercased() }.joined()
    if !initials.isEmpty, initials.rangeOfCharacter(from: .letters) != nil { return initials }
    if !initials.isEmpty { return String(initials.prefix(1)) }
    return String(title.prefix(1)).uppercased()
  }

  private var platformBadge: some View {
    Circle()
      .fill(DS.Color.green(colorScheme))
      .frame(width: size * 0.34, height: size * 0.34)
      .overlay(
        Image(systemName: "phone.fill")
          .font(.system(size: size * 0.17, weight: .bold))
          .foregroundStyle(.white)
      )
      .overlay(
        Circle().strokeBorder(DS.Color.g080(colorScheme), lineWidth: 1.5)
      )
  }
}
