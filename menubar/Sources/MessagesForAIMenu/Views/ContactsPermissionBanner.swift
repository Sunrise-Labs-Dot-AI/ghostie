import SwiftUI
import Contacts

// Sister banner to FDABanner, shown when the menu bar app's Contacts
// authorization is not `.authorized`. The product reasoning:
// CNContactStore is the user-facing path for contact name resolution —
// it sees iCloud-synced data and pops a native consent dialog. When
// it's denied, we want the user to know the menu bar app is the
// gating dependency (not Full Disk Access on the MCP binary), and we
// want to make granting one click away.
//
// Behavior by status:
//   - .notDetermined → "Allow Contacts access" button calls
//     ContactsExporter.requestAccessAndExport() which fires the native
//     "Ghostie would like to access your Contacts" dialog.
//   - .denied / .restricted → "Open Contacts Settings" button deep-links
//     to System Settings → Privacy & Security → Contacts where the
//     user can flip the toggle.
//   - .authorized → banner renders nothing.
struct ContactsPermissionBanner: View {
  @EnvironmentObject var exporter: ContactsExporter
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if exporter.authorizationStatus != .authorized {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle.badge.exclamationmark")
            .foregroundStyle(DS.Color.accentTeal(colorScheme))
          Text(headlineText)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
        }
        Text(bodyText)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button(actionLabel) {
            Task { await primaryAction() }
          }
          .dsButton(.primary, size: .small)
          if exporter.authorizationStatus == .denied || exporter.authorizationStatus == .restricted {
            Button("Recheck") {
              Task { await exporter.exportNow() }
            }
            .dsButton(.secondary, size: .small)
          }
        }
      }
      .padding(DS.Space.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
          .fill(DS.Color.g130(colorScheme))
      )
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.card)
    }
  }

  // MARK: - Status-driven copy

  private var headlineText: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow Contacts access"
    case .denied:        return "Contacts access denied"
    case .restricted:    return "Contacts access restricted by policy"
    default:             return "Contacts access unavailable"
    }
  }

  private var bodyText: String {
    switch exporter.authorizationStatus {
    case .notDetermined:
      return "Ghostie uses Contacts to resolve recipient names. This is the same data Messages.app sees, including iCloud-synced contacts."
    case .denied:
      return "Open System Settings → Privacy & Security → Contacts and turn on Ghostie. Then click Recheck."
    case .restricted:
      return "Your organization's device policy disallows Contacts access. Names will fall back to the local address book and may miss iCloud-only contacts."
    default:
      return "An unexpected Contacts authorization status was reported."
    }
  }

  private var actionLabel: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow…"
    default:             return "Open Settings"
    }
  }

  private func primaryAction() async {
    switch exporter.authorizationStatus {
    case .notDetermined:
      await exporter.requestAccessAndExport()
    default:
      ContactsExporter.openContactsSettings()
    }
  }
}
