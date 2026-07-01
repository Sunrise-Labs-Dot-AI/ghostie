import SwiftUI
import AppKit

struct TextingVoiceView: View {
  @EnvironmentObject var textingVoice: TextingVoiceController
  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var settingsFocus: SettingsFocusController
  @Environment(\.colorScheme) private var colorScheme
  @State private var editing: EditableVoice?
  @State private var showingPrimer = false
  @State private var styleHandoffNotice: TextingStyleHandoffNotice?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if isBusy || !textingVoice.generationLog.isEmpty {
          generationProgress
        }
        if textingVoice.profile != nil {
          completedVoiceSurface
        } else if !textingVoice.hasAnyAPIKey {
          missingKeyState
        } else if !textingVoice.canGenerateWithSelectedProvider {
          selectedProviderNeedsKeyState
        } else {
          readyToGenerateState
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(DS.Color.g100(colorScheme))
    .sheet(isPresented: $showingPrimer) {
      TextingVoicePrimerSheet(
        providerName: textingStyleProvider.label,
        includeIdentityHints: textingVoice.includeIdentityHints,
        onGenerate: {
          showingPrimer = false
          textingVoice.generateVoice()
        }
      )
      .frame(width: 560, height: 460)
    }
    .sheet(item: $editing) { item in
      VoiceGuideEditor(item: item) { profileID, markdown in
        textingVoice.saveGuide(profileID: profileID, markdown: markdown)
      }
      .frame(width: 680, height: 620)
    }
    .onAppear {
      if textingVoice.profile == nil, textingVoice.canGenerateWithSelectedProvider {
        showingPrimer = true
      }
    }
    .onChange(of: textingVoice.canGenerateWithSelectedProvider) { _, canGenerate in
      if canGenerate, textingVoice.profile == nil {
        showingPrimer = true
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Texting Style")
          .font(DS.Font.paneTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(headerPrivacyLine)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      Spacer()
      if textingVoice.profile != nil {
        Button {
          showingPrimer = true
        } label: {
          Label("Regenerate", systemImage: "wand.and.stars")
        }
        .dsButton(.primary)
        .disabled(!textingVoice.canGenerateWithSelectedProvider || isBusy)
      }
    }
  }

  private var textingStyleProvider: TextingVoiceProvider {
    textingVoice.selectedProvider(for: .textingStyle) ?? textingVoice.selectedProvider
  }

  private var completedVoiceSurface: some View {
    VStack(alignment: .leading, spacing: 18) {
      heroVoice
      generationFooter
      if !textingVoice.specificProfiles.isEmpty {
        profileSection("People-specific styles", profiles: textingVoice.specificProfiles, icon: "person")
      }
      if !textingVoice.typeProfiles.isEmpty {
        profileSection("People-type styles", profiles: textingVoice.typeProfiles, icon: "person.2")
      }
    }
  }

  private var missingKeyState: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Add an API key in Settings", systemImage: "key")
        .font(.headline)
      Text("Texting Style uses a model to turn local aggregate texting patterns into an editable drafting guide. Add a Claude or ChatGPT key first.")
        .font(.callout)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Button {
        openAISettings()
      } label: {
        Label("Open Settings", systemImage: "arrow.up.right.square")
      }
      .dsButton(.primary)
    }
    .padding(22)
    .frame(maxWidth: 560, alignment: .leading)
    .dsCard(colorScheme)
  }

  private var selectedProviderNeedsKeyState: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("\(textingStyleProvider.label) key needed", systemImage: "key")
        .font(.headline)
      Text("A key is saved for another provider, but Texting Style is set to use \(textingStyleProvider.label). Choose the saved provider or add this key in Settings.")
        .font(.callout)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Button {
        openAISettings()
      } label: {
        Label("Open Settings", systemImage: "arrow.up.right.square")
      }
      .dsButton(.primary)
    }
    .padding(22)
    .frame(maxWidth: 600, alignment: .leading)
    .dsCard(colorScheme)
  }

  private var readyToGenerateState: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Ready to generate", systemImage: "sparkles")
        .font(.headline)
      Text("Before building your style, Ghostie will show a short primer about what gets analyzed, what the model sees, and how the final guide can be edited.")
        .font(.callout)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button {
          showingPrimer = true
        } label: {
          Label("Review Primer", systemImage: "rectangle.stack")
        }
        .dsButton(.primary)
        if isBusy {
          ProgressView().controlSize(.small)
          Text(textingVoice.status.label)
            .font(.caption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }
    }
    .padding(22)
    .frame(maxWidth: 620, alignment: .leading)
    .dsCard(colorScheme)
  }

  private var heroVoice: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Label("Generated style", systemImage: "waveform")
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          if let profile = textingVoice.profile {
            Text("\(profile.sample_size) messages analyzed · \(shortDate(profile.window_start)) to \(shortDate(profile.window_end))")
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
        }
        Spacer()
        statusPill
      }

      if let profile = textingVoice.profile {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
          metric("Typical length", "\(profile.length.median) chars")
          metric("No punctuation", percent(profile.punctuation.pct_ending_none))
          metric("Emoji", percent(profile.emoji.pct_messages_with_emoji))
          metric("Bursts", "\(profile.bursts.median_messages_per_burst) msg median")
        }

        guidePreview(profileID: "base", fallbackTitle: "Base texting style")

        HStack(spacing: 10) {
          Button {
            edit(profileID: "base", title: "Generated style")
          } label: {
            Label("Inspect or edit", systemImage: "pencil")
          }
          .dsButton(.secondary, size: .small)

          Button {
            NSWorkspace.shared.open(TextingVoiceController.baseDirectory)
          } label: {
            Label("Reveal files", systemImage: "folder")
          }
          .dsButton(.secondary, size: .small)

          Spacer()
        }
      } else {
        Text(textingVoice.status.label)
          .font(.callout)
          .foregroundStyle(statusTint)
      }
    }
    .padding(18)
    .dsCard(colorScheme)
  }

  private var generationFooter: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Generation", systemImage: "sparkles")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
        Text(textingVoice.canGenerateWithSelectedProvider ? "Using \(textingVoice.modelDisplayName(for: .textingStyle, provider: textingStyleProvider))" : "Key needed in Settings")
          .font(DS.Font.chip)
          .foregroundStyle(textingVoice.canGenerateWithSelectedProvider ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
              .fill(textingVoice.canGenerateWithSelectedProvider ? DS.Color.greenDim(colorScheme) : DS.Color.g160(colorScheme))
          )
      }

      HStack {
        Text("Provider and keys live in Settings. Regeneration reruns the primer, refreshes aggregate fingerprints, and rewrites the editable guides. \(textingVoice.modelCostLabel(for: .textingStyle, provider: textingStyleProvider)).")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        Spacer()
        Button {
          openAISettings()
        } label: {
          Label("AI Settings", systemImage: "key")
        }
        .dsButton(.secondary, size: .small)
        Button {
          showingPrimer = true
        } label: {
          Label("Regenerate", systemImage: "wand.and.stars")
        }
        .dsButton(.primary, size: .small)
        .disabled(!textingVoice.canGenerateWithSelectedProvider || isBusy)
      }

      Divider()
        .padding(.vertical, 2)

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Button {
            bringStyle(to: .claude)
          } label: {
            Label("Bring to Claude", systemImage: DraftAssistant.claude.symbol)
          }
          .dsButton(.secondary, size: .small)

          Button {
            bringStyle(to: .codex)
          } label: {
            Label("Bring to Codex", systemImage: DraftAssistant.codex.symbol)
          }
          .dsButton(.secondary, size: .small)

          Button {
            copyStylePrompt()
          } label: {
            Label("Copy prompt", systemImage: "doc.on.clipboard")
          }
          .dsButton(.secondary, size: .small)

          Spacer()
        }

        Text("Copies a prompt that points assistants to this generated style, asks them to prefer the Ghostie MCP when available, and keeps sending staged for your approval.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)

        if let notice = styleHandoffNotice {
          Label(notice.text, systemImage: notice.isWarning ? "exclamationmark.triangle.fill" : "doc.on.clipboard")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(notice.isWarning ? DS.Color.amber(colorScheme) : DS.Color.ink3(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(14)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme))
  }

  private func profileSection(_ title: String, profiles: [TextingVoiceProfileSummary], icon: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
        ForEach(profiles) { profile in
          profileCard(profile, icon: icon)
        }
      }
    }
  }

  private var generationProgress: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if isBusy {
          ProgressView().controlSize(.small)
        } else if case .failed = textingVoice.status {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(DS.Color.red)
        } else {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(DS.Color.green(colorScheme))
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(textingVoice.status.label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text(progressPrivacyLine)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !textingVoice.generationLog.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(textingVoice.generationLog.enumerated()), id: \.offset) { idx, entry in
            HStack(alignment: .firstTextBaseline, spacing: 7) {
              Image(systemName: idx == textingVoice.generationLog.count - 1 && isBusy ? "circle.dotted" : "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(idx == textingVoice.generationLog.count - 1 && isBusy ? DS.Color.amber(colorScheme) : DS.Color.ink3(colorScheme))
              Text(entry)
                .font(DS.Font.settingsCaption)
                .foregroundStyle(DS.Color.ink3(colorScheme))
            }
          }
        }
        .padding(.leading, 2)
      }
    }
    .padding(14)
    .frame(maxWidth: 660, alignment: .leading)
    .dsCard(colorScheme)
  }

  private func profileCard(_ profile: TextingVoiceProfileSummary, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.displayName)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
          Text(profile.scopeLabel)
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
      }

      HStack(spacing: 8) {
        smallChip("\(profile.sampleSize)", systemImage: "bubble.left.and.bubble.right")
        smallChip("\(profile.medianLength) chars", systemImage: "textformat.size")
      }

      guidePreview(profileID: profile.id, fallbackTitle: profile.displayName, lineLimit: 4)

      Button {
        edit(profileID: profile.id, title: profile.displayName)
      } label: {
        Label("Inspect or edit", systemImage: "pencil")
      }
      .dsButton(.secondary, size: .small)
    }
    .padding(12)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.row)
  }

  private func guidePreview(profileID: String, fallbackTitle: String, lineLimit: Int = 7) -> some View {
    let guide = textingVoice.guideText(for: profileID)
    return Text(guide.isEmpty ? "Build the local style, then enhance it with AI to create an editable drafting guide." : guide.cleanedMarkdownPreview(fallbackTitle: fallbackTitle))
      .font(.callout)
      .foregroundStyle(guide.isEmpty ? DS.Color.ink3(colorScheme) : DS.Color.ink(colorScheme))
      .lineLimit(lineLimit)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func edit(profileID: String, title: String) {
    editing = EditableVoice(
      profileID: profileID,
      title: title,
      markdown: textingVoice.guideText(for: profileID)
    )
  }

  private func bringStyle(to assistant: DraftAssistant) {
    let prompt = textingStylePrompt(for: assistant)
    let outcome = DraftHandoff.dispatch(assistant, prompt: prompt, claudeTarget: .chat)
    styleHandoffNotice = TextingStyleHandoffNotice(
      text: outcome.message(assistant: assistant),
      isWarning: outcome.isWarning
    )
  }

  private func copyStylePrompt() {
    let prompt = textingStylePrompt(for: nil)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(prompt, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    styleHandoffNotice = TextingStyleHandoffNotice(text: "Prompt copied to clipboard", isWarning: false)
  }

  private func textingStylePrompt(for assistant: DraftAssistant?) -> String {
    let baseGuidePath = TextingVoiceController.baseDirectory.appendingPathComponent("GUIDE.md").path
    let fallbackGuidePath = TextingVoiceController.baseDirectory.appendingPathComponent("VOICE.md").path
    let voiceRoot = TextingVoicePaths.voiceRoot.path
    let baseGuide = textingVoice.guideText(for: "base").trimmingCharacters(in: .whitespacesAndNewlines)
    let assistantLine: String = {
      switch assistant {
      case .claude:
        return "For Claude: prefer the Ghostie MCP tools if they are available in this session."
      case .codex:
        return "For Codex: prefer reading the local guide files when available; use the MCP tools if they are configured in this session."
      case nil:
        return "For Claude or Codex: use whichever of MCP tools, local files, or the inline fallback is available in this session."
      }
    }()

    let inlineGuide = baseGuide.isEmpty ? "" : """

    Inline fallback base style guide:
    ```markdown
    \(baseGuide)
    ```
    """

    return """
    Use my Ghostie Style before drafting text messages.

    \(assistantLine)

    Preferred lookup order:
    1. If Ghostie MCP tools are available, call `get_texting_style` with `profile: "base"`. You may also call `list_texting_style_profiles` and use a more specific profile if the user or thread clearly identifies one.
    2. If local files are accessible, read the base style guide at:
       \(baseGuidePath)
       If that file is missing, fall back to:
       \(fallbackGuidePath)
       People-specific and people-type profiles live under:
       \(voiceRoot)
    3. If neither MCP nor local files are available, use the inline fallback below.

    Use the style only for tone, length, warmth, punctuation, opener/closer habits, and what to avoid. Fresh thread context should override the style when the situation is serious, formal, logistical, or emotionally sensitive.

    Hard rule: never send automatically. Only stage drafts for my human approval through Ghostie.
    \(inlineGuide)
    """
  }

  private func openAISettings() {
    settingsFocus.target = .ai
    nav.selection = .settings
  }

  private var statusPill: some View {
    Text(textingVoice.status.label)
      .font(DS.Font.chip)
      .foregroundStyle(statusTint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
          .fill(statusTint.opacity(0.14))
      )
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.system(size: 17, weight: .semibold, design: .monospaced))
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text(label)
        .font(DS.Font.monoMicro)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
  }

  private func smallChip(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(DS.Font.chip)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
          .fill(DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12))
      )
      .foregroundStyle(DS.Color.accentTeal(colorScheme))
  }

  private var isBusy: Bool {
    if case .loading = textingVoice.status { return true }
    if case .enhancing = textingVoice.status { return true }
    return false
  }

  private var progressPrivacyLine: String {
    textingVoice.includeIdentityHints
      ? "The model receives aggregate style fingerprints plus sanitized identity hints, not raw message bodies, phone numbers, emails, or raw handles."
      : "The model receives aggregate style fingerprints with profile IDs, not raw message bodies, contact names, phone numbers, or emails."
  }

  private var headerPrivacyLine: String {
    textingVoice.includeIdentityHints
      ? "A local style guide assistants can use while drafting. AI enhancement uses aggregate fingerprints plus sanitized identity hints; raw messages, phone numbers, emails, and raw handles are not sent."
      : "A local style guide assistants can use while drafting. AI enhancement uses privacy-scrubbed aggregate fingerprints; raw messages and recipient identities are not sent."
  }

  private var refreshTitle: String {
    textingVoice.profile == nil ? "Build Style" : "Refresh Style"
  }

  private var statusTint: Color {
    if case .failed = textingVoice.status { return DS.Color.red }
    if case .loading = textingVoice.status { return DS.Color.amber(colorScheme) }
    if case .enhancing = textingVoice.status { return DS.Color.amber(colorScheme) }
    return DS.Color.ink3(colorScheme)
  }

  private func percent(_ value: Double) -> String {
    "\(Int(round(value * 100)))%"
  }

  private func shortDate(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

private struct EditableVoice: Identifiable {
  let profileID: String
  let title: String
  let markdown: String
  var id: String { profileID }
}

private struct TextingStyleHandoffNotice: Equatable {
  let text: String
  let isWarning: Bool
}

private struct TextingVoicePrimerSheet: View {
  let providerName: String
  let includeIdentityHints: Bool
  let onGenerate: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var page = 0

  private var pages: [(icon: String, title: String, body: String)] {
    [
      (
        "waveform",
        "What Texting Style Is",
        "Texting Style is a local drafting guide for assistants. It helps future drafts sound closer to you: how brief you are, how polished or casual you are, how you use punctuation, and how your tone changes by conversation."
      ),
      (
        "chart.bar.doc.horizontal",
        "How It Is Generated",
        "Ghostie scans sent messages locally, then builds aggregate fingerprints: length, punctuation, opener patterns, burst shape, and broad conversation buckets. The model turns those fingerprints into readable guidance for your overall style, frequent people, and broad people-type patterns."
      ),
      (
        "lock.shield",
        "Privacy",
        includeIdentityHints
          ? "Raw message bodies are not sent. Phone numbers, emails, and raw handles are excluded; first-name or group-label hints may be sent to improve people-specific tone. The finished guides are saved on this Mac, and you can inspect or edit them before assistants use them."
          : "Raw message bodies are not sent. Recipient names, phone numbers, and emails are replaced with profile IDs before the model call. The finished guides are saved on this Mac, and you can inspect or edit them before assistants use them."
      )
    ]
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .dsButton(.ghost)
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)

      Spacer(minLength: 10)

      VStack(spacing: 18) {
        Image(systemName: pages[page].icon)
          .font(.system(size: 42, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .frame(width: 64, height: 64)
        Text(pages[page].title)
          .font(.system(size: 24, weight: .bold))
        Text(pages[page].body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 430)
        Text("Provider: \(providerName)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      .padding(.horizontal, 36)

      Spacer()

      HStack {
        Button("Back") {
          page = max(0, page - 1)
        }
        .dsButton(.secondary)
        .disabled(page == 0)

        Spacer()

        HStack(spacing: 6) {
          ForEach(0..<pages.count, id: \.self) { idx in
            Circle()
              .fill(idx == page ? Color.accentColor : Color.secondary.opacity(0.25))
              .frame(width: 7, height: 7)
          }
        }

        Spacer()

        if page < pages.count - 1 {
          Button("Next") {
            page += 1
          }
          .dsButton(.primary)
        } else {
          Button {
            onGenerate()
          } label: {
            Label("Generate Style", systemImage: "wand.and.stars")
          }
          .dsButton(.primary)
        }
      }
      .padding(18)
    }
  }
}

private struct VoiceGuideEditor: View {
  let item: EditableVoice
  let onSave: (String, String) -> Void
  @EnvironmentObject private var textingVoice: TextingVoiceController
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var markdown: String
  @State private var prompt = ""
  @State private var applyingPrompt = false

  init(item: EditableVoice, onSave: @escaping (String, String) -> Void) {
    self.item = item
    self.onSave = onSave
    _markdown = State(initialValue: item.markdown)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(.system(size: 20, weight: .bold))
          Text("Edit the local guide assistants can read while drafting.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .dsButton(.ghost)
      }
      .padding(18)

      Divider()

      TextEditor(text: $markdown)
        .font(.body)
        .padding(12)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          TextField("Ask AI to adjust this style...", text: $prompt, axis: .vertical)
            .dsInput(colorScheme, minHeight: 58)
            .lineLimit(1...3)
          Button {
            applyPrompt()
          } label: {
            if applyingPrompt {
              ProgressView().controlSize(.small)
            } else {
              Label("Apply", systemImage: "wand.and.stars")
            }
          }
          .dsButton(.secondary)
          .disabled(
            applyingPrompt
              || !textingVoice.canGenerateWithSelectedProvider
              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
        if !textingVoice.canGenerateWithSelectedProvider {
          Text("Prompt edits need the selected provider key in Settings.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }
            .dsButton(.secondary)
          Button("Save") {
            onSave(item.profileID, markdown)
            dismiss()
          }
          .dsButton(.primary)
          .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(18)
    }
  }

  private func applyPrompt() {
    applyingPrompt = true
    let instruction = prompt
    Task {
      if let revised = await textingVoice.reviseGuide(
        profileID: item.profileID,
        title: item.title,
        currentMarkdown: markdown,
        instruction: instruction
      ) {
        markdown = revised
        prompt = ""
      }
      applyingPrompt = false
    }
  }
}

private extension TextingVoiceProfileSummary {
  var scopeLabel: String {
    switch scope {
    case "conversation-outbound-imessage": return "Person-specific"
    case "person-type-outbound-imessage": return "People type"
    default: return scope
    }
  }
}

private extension String {
  func cleanedMarkdownPreview(fallbackTitle: String) -> String {
    let lines = components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { line -> String in
        if line.hasPrefix("#") {
          let title = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
          let lowered = title.lowercased()
          if lowered.contains("chat-") || lowered.contains("[redacted") {
            return fallbackTitle
          }
          return title
        }
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        return line
      }
    return lines.isEmpty ? fallbackTitle : lines.prefix(8).joined(separator: "\n")
  }
}
