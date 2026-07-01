import SwiftUI

struct DSSegmentedControl<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String
  let accessibilityLabel: (Option) -> String
  let icon: (Option) -> String?

  @Environment(\.colorScheme) private var colorScheme

  init(
    _ options: [Option],
    selection: Binding<Option>,
    label: @escaping (Option) -> String,
    accessibilityLabel: @escaping (Option) -> String,
    icon: @escaping (Option) -> String? = { _ in nil }
  ) {
    self.options = options
    self._selection = selection
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.icon = icon
  }

  init(
    _ options: [Option],
    selection: Binding<Option>,
    label: @escaping (Option) -> String,
    icon: @escaping (Option) -> String? = { _ in nil }
  ) {
    self.init(
      options,
      selection: selection,
      label: label,
      accessibilityLabel: label,
      icon: icon
    )
  }

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options, id: \.self) { option in
        Button {
          withAnimation(.easeInOut(duration: 0.14)) {
            selection = option
          }
        } label: {
          HStack(spacing: 6) {
            if let icon = icon(option) {
              Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            }
            Text(label(option))
              .lineLimit(1)
              .minimumScaleFactor(0.82)
          }
          .font(DS.Font.chip)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 8)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: DS.Radius.control - 2, style: .continuous)
              .fill(selection == option ? DS.Color.g050(colorScheme) : Color.clear)
          )
          .foregroundStyle(selection == option ? DS.Color.accentTeal(colorScheme) : DS.Color.ink3(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(option))
        .accessibilityValue(selection == option ? "Selected" : "")
        .accessibilityAddTraits(selection == option ? .isSelected : [])
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(DS.Color.g130(colorScheme))
    )
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.control)
  }
}

struct DSCheckbox: View {
  let title: String
  let subtitle: String?
  @Binding var isOn: Bool
  var enabled = true

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button {
      guard enabled else { return }
      withAnimation(.easeInOut(duration: 0.14)) {
        isOn.toggle()
      }
    } label: {
      HStack(alignment: .top, spacing: 9) {
        ZStack {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? DS.Color.accentTeal(colorScheme) : DS.Color.g050(colorScheme))
            .frame(width: 16, height: 16)
            .dsHairline(colorScheme, isOn ? { scheme in DS.Color.accentTeal(scheme) } : DS.Color.lineStrong, radius: 4)
          if isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white)
          }
        }
        .padding(.top, 1)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          if let subtitle {
            Text(subtitle)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .opacity(enabled ? 1 : 0.55)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "On" : "Off")
  }
}

struct DSSwitch: View {
  let label: String
  @Binding var isOn: Bool
  var enabled = true

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.14)) {
        isOn.toggle()
      }
    } label: {
      ZStack(alignment: isOn ? .trailing : .leading) {
        Capsule()
          .fill(isOn ? DS.Color.g260(colorScheme) : DS.Color.g200(colorScheme))
          .frame(width: 38, height: 22)
          .overlay(
            Capsule()
              .strokeBorder(isOn ? DS.Color.lineStrong(colorScheme) : DS.Color.line2(colorScheme), lineWidth: 1)
          )
        Circle()
          .fill(isOn ? DS.Color.ink(colorScheme) : DS.Color.ink2(colorScheme))
          .frame(width: 16, height: 16)
          .padding(3)
      }
      .opacity(enabled ? 1 : 0.55)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .animation(.easeInOut(duration: 0.15), value: isOn)
    .accessibilityLabel(label)
    .accessibilityValue(isOn ? "on" : "off")
    .accessibilityHint(enabled ? "Toggles \(label)" : "Disabled")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

struct DSDateTimeField: View {
  let title: String
  @Binding var selection: Date
  var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]

  @Environment(\.colorScheme) private var colorScheme
  @State private var showingPicker = false

  var body: some View {
    Button {
      showingPicker.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: displayedComponents.contains(.hourAndMinute) ? "clock" : "calendar")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .textCase(.uppercase)
          Text(formatted(selection))
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(DS.Color.g130(colorScheme))
      )
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.control)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        DatePicker("", selection: $selection, displayedComponents: displayedComponents)
          .labelsHidden()
          .datePickerStyle(.compact)
        Button("Done") {
          showingPicker = false
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
      .padding(14)
      .frame(minWidth: 260, alignment: .leading)
      .background(DS.Color.g100(colorScheme))
    }
    .accessibilityLabel(title)
    .accessibilityValue(formatted(selection))
  }

  private func formatted(_ date: Date) -> String {
    if displayedComponents.contains(.date), displayedComponents.contains(.hourAndMinute) {
      return Self.dateTimeFormatter.string(from: date)
    }
    if displayedComponents.contains(.date) {
      return Self.dateFormatter.string(from: date)
    }
    return Self.timeFormatter.string(from: date)
  }

  private static let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter
  }()

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
}

struct DSStepperField: View {
  let title: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  var suffix: String?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Spacer(minLength: 8)
      stepButton("minus") { value = max(range.lowerBound, value - 1) }
        .disabled(value <= range.lowerBound)
      Text(valueText)
        .font(DS.Font.monoValue)
        .foregroundStyle(DS.Color.ink(colorScheme))
        .frame(minWidth: 56)
      stepButton("plus") { value = min(range.upperBound, value + 1) }
        .disabled(value >= range.upperBound)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(DS.Color.g130(colorScheme))
    )
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.control)
  }

  private var valueText: String {
    if let suffix { return "\(value) \(suffix)" }
    return "\(value)"
  }

  private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 20, height: 20)
        .background(Circle().fill(DS.Color.g050(colorScheme)))
        .dsHairline(colorScheme, DS.Color.line, radius: 10)
    }
    .buttonStyle(.plain)
  }
}

struct DSMenuPicker<Option: Hashable>: View {
  let title: String
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button {
          selection = option
        } label: {
          if option == selection {
            Label(label(option), systemImage: "checkmark")
          } else {
            Text(label(option))
          }
        }
      }
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .textCase(.uppercase)
          Text(label(selection))
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(DS.Color.g130(colorScheme))
      )
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.control)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(label(selection))
  }
}
