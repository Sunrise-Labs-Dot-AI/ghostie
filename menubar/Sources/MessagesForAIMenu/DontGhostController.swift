import Foundation
import SQLite3

/// What kind of nudge a suggestion is.
/// - `owedReply`: the other person sent the last substantive message and the
///   user hasn't answered — the ball is in their court.
/// - `followUp`: the user sent last (or it mutually went quiet) and enough time
///   has passed that a warm check-in / reconnect would feel natural.
enum DontGhostKind: String, Codable, Equatable {
  case owedReply
  case followUp
}

struct DontGhostMessage: Identifiable, Equatable {
  let id: Int64
  let fromMe: Bool
  let senderName: String?
  let body: String
  let sentAt: Date

  var contextMessage: ContextMessage {
    ContextMessage(
      from_me: fromMe,
      sender_handle: nil,
      sender_name: senderName,
      body: body,
      sent_at: DontGhostController.iso(sentAt)
    )
  }
}

struct DontGhostSuggestion: Identifiable, Equatable {
  let threadID: Int
  let platform: Platform
  let displayName: String
  let handle: String
  let lastInboundAt: Date
  let lastMessageAt: Date
  let messages: [DontGhostMessage]
  var kind: DontGhostKind = .owedReply
  var reason: String
  var confidence: Double
  var draftText: String = ""
  var status: String?

  var id: String { "\(platform.rawValue):\(threadID)" }
  var effectivePlatform: Platform { platform }
  /// The dismissal / cache / re-surface anchor. Generalized to the LAST MESSAGE
  /// timestamp (any direction) so a thread re-surfaces when ANY new message
  /// arrives. Backward-compatible for owed-reply rows: there `lastMessageAt ==
  /// lastInboundAt`, so the stored key is identical to the legacy
  /// `iso(lastInboundAt)` and old dismissal files still suppress them.
  var lastMessageKey: String { DontGhostController.iso(lastMessageAt) }
  /// Legacy alias retained for callers/tests that referenced the inbound anchor.
  var lastInboundKey: String { DontGhostController.iso(lastInboundAt) }
  var lastInboundPreview: String {
    messages.last(where: { !$0.fromMe })?.body ?? ""
  }
}

enum DontGhostError: Error {
  case chatDbMissing
  case sqliteOpen(String)
  case sqlitePrepare(String)
  case noAPIKey
  case noStyleGuide
  case invalidResponse
}

@MainActor
final class DontGhostController: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading(String)
    case ready(Date)
    case failed(String)

    var label: String {
      switch self {
      case .idle: return "Ready"
      case .loading(let message): return message
      case .ready(let date): return "Updated \(TextingVoicePaths.relative(date))"
      case .failed(let message): return message
      }
    }
  }

  @Published private(set) var suggestions: [DontGhostSuggestion] = []
  @Published private(set) var status: Status = .idle
  @Published private(set) var isBusy = false
  @Published private(set) var isLoadingCache = false

  /// Set by DontGhostView from the environment so the optional AI boost is
  /// metered and budget-gated (issue #145). nil → no metering / no gate.
  var usageLedger: AIUsageLedger?

  private let dismissals = DontGhostDismissalStore()
  private let cache = DontGhostCacheStore()

  init() {
    loadCachedResults()
  }

  var hasAnyAPIKey: Bool {
    TextingVoiceKeychain.hasAPIKey(.anthropic) || TextingVoiceKeychain.hasAPIKey(.openAI)
  }

  func refresh() {
    refresh(store: nil)
  }

  func refresh(store: DraftStore?) {
    let startedAt = Date()
    let pendingDrafts = store?.drafts ?? []
    DiagnosticsStore.shared.log("dont_ghost.scan_started", metadata: [
      "ai_enabled": hasAnyAPIKey && LabModelPreferences.dontGhostAIBoostEnabled,
      "cached_count": cache.load().count,
      "pending_draft_count": pendingDrafts.filter { !$0.isSent }.count
    ])
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.dontGhost.rawValue)
    ])
    isBusy = true
    // AI boost: the optional LLM refinement runs only when a key exists AND the
    // user has the boost on. Off → fully deterministic, on-device, no cost.
    // A reached budget cap also falls back to the deterministic surface (no
    // user-facing failure) — the precheck records the blocked attempt.
    let aiEnabled = hasAnyAPIKey && LabModelPreferences.dontGhostAIBoostEnabled
    let aiAllowed = aiEnabled && AIBudgetPrecheck.allow(lab: .dontGhost, ledger: usageLedger)
    status = .loading(aiAllowed ? "Finding quiet conversations worth a nudge..." : "Scanning on-device...")
    let recorder = usageLedger
    let runID = UUID()
    Task.detached(priority: .userInitiated) {
      do {
        var candidates = try DontGhostScanner.loadCandidates(aiEnabled: aiAllowed)
          .filter { self.dismissals.shouldShow(threadID: $0.threadID, lastMessageKey: $0.lastMessageKey) }
        DiagnosticsStore.shared.log("dont_ghost.candidates_loaded", metadata: [
          "candidate_count": candidates.count
        ])
        if aiAllowed, let client = DontGhostLLMClient.available(recorder: recorder, runID: runID) {
          await MainActor.run { self.status = .loading("Reasoning over which threads to nudge and which to let rest...") }
          candidates = try await client.classify(candidates)
          DiagnosticsStore.shared.log("dont_ghost.ai_classified", metadata: [
            "candidate_count": candidates.count
          ])
        }
        let finalCandidates = candidates.sorted(by: Self.byRecency)
        let hydratedCached = (try? DontGhostScanner.hydrate(self.cache.load())) ?? []
        await MainActor.run {
          let merged = Self.merge(current: finalCandidates, cached: hydratedCached)
            .filter { self.dismissals.shouldShow(threadID: $0.threadID, lastMessageKey: $0.lastMessageKey) }
          let visible = Self.suggestionsExcludingPendingWork(merged, drafts: pendingDrafts)
          self.suggestions = visible
          self.cache.save(visible)
          self.status = .ready(Date())
          self.isBusy = false
          DiagnosticsStore.shared.log("dont_ghost.scan_completed", metadata: [
            "result_count": visible.count,
            "current_count": finalCandidates.count,
            "hydrated_cached_count": hydratedCached.count,
            "suppressed_pending_count": merged.count - visible.count,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
          ])
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.dontGhost.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(visible.count)),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch {
        await MainActor.run {
          self.status = .failed(Self.userFacingError(error))
          self.isBusy = false
          DiagnosticsStore.shared.log("dont_ghost.scan_failed", metadata: [
            "error_type": String(describing: type(of: error)),
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
          ])
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.dontGhost.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  func suppressPendingWork(from drafts: [Draft]) {
    let visible = Self.suggestionsExcludingPendingWork(suggestions, drafts: drafts)
    guard visible.count != suggestions.count else { return }
    DiagnosticsStore.shared.log("dont_ghost.pending_suppressed", metadata: [
      "suppressed_pending_count": suggestions.count - visible.count
    ])
    suggestions = visible
    cache.save(visible)
  }

  func dismiss(_ suggestion: DontGhostSuggestion) {
    DiagnosticsStore.shared.log("dont_ghost.dismissed", metadata: [
      "kind": suggestion.kind.rawValue,
      "age_hours": Int(Date().timeIntervalSince(suggestion.lastMessageAt) / 3600)
    ])
    dismissals.dismiss(threadID: suggestion.threadID, lastMessageKey: suggestion.lastMessageKey)
    cache.remove(threadID: suggestion.threadID)
    suggestions.removeAll { $0.id == suggestion.id }
  }

  func markReplied(_ suggestion: DontGhostSuggestion) {
    DiagnosticsStore.shared.log("dont_ghost.replied", metadata: [
      "kind": suggestion.kind.rawValue,
      "age_hours": Int(Date().timeIntervalSince(suggestion.lastMessageAt) / 3600)
    ])
    cache.remove(threadID: suggestion.threadID)
    suggestions.removeAll { $0.id == suggestion.id }
  }

  func updateDraftText(threadID: Int, text: String) {
    guard let idx = suggestions.firstIndex(where: { $0.threadID == threadID }) else { return }
    suggestions[idx].draftText = text
    cache.save(suggestions)
  }

  func stageManualDraft(_ suggestion: DontGhostSuggestion, store: DraftStore) -> Draft? {
    queueDraft(suggestion, body: suggestion.draftText, scheduledAt: nil, store: store)
  }

  func sendNow(_ suggestion: DontGhostSuggestion, existingDraft: Draft?, store: DraftStore) async -> Draft? {
    DiagnosticsStore.shared.log("dont_ghost.send_now_started", metadata: [
      "used_existing_draft": existingDraft != nil
    ])
    let draft: Draft
    if let existingDraft {
      draft = existingDraft
    } else if let queued = queueDraft(suggestion, body: suggestion.draftText, scheduledAt: nil, store: store) {
      draft = queued
    } else {
      return nil
    }

    mark(suggestion.threadID, status: "Sending reply...")
    let result = await DraftSender.send(draft: draft)
    if result.ok, let service = result.service {
      if draft.effectivePlatform == .imessage {
        do {
          try store.markSent(id: draft.id, sentAt: Date(), service: service)
        } catch {
          mark(suggestion.threadID, status: "Sent, but couldn't update the draft file: \(error.localizedDescription)")
          return draft
        }
      } else {
        store.refresh()
      }
      markReplied(suggestion)
      DiagnosticsStore.shared.log("dont_ghost.send_now_completed", metadata: [
        "platform": draft.effectivePlatform.rawValue
      ])
      return nil
    }

    mark(suggestion.threadID, status: result.error ?? "Send failed.")
    DiagnosticsStore.shared.log("dont_ghost.send_now_failed", metadata: [
      "platform": draft.effectivePlatform.rawValue,
      "has_error": result.error != nil
    ])
    return draft
  }

  func scheduleDraft(_ suggestion: DontGhostSuggestion, scheduledAt: Date, store: DraftStore) {
    DiagnosticsStore.shared.log("dont_ghost.schedule_queued", metadata: [
      "scheduled_in_minutes": Int(scheduledAt.timeIntervalSince(Date()) / 60)
    ])
    _ = queueDraft(suggestion, body: suggestion.draftText, scheduledAt: scheduledAt, approveScheduledDraft: true, store: store)
  }

  // Auto-draft was removed (v0.8): Don't Ghost surfaces and ranks on-device, and
  // you write the reply (or hand it to an agent via the MCP). The LLM is an
  // optional surfacing refinement only — it no longer drafts on your behalf.

  private func queueDraft(
    _ suggestion: DontGhostSuggestion,
    body: String,
    scheduledAt: Date?,
    approveScheduledDraft: Bool = false,
    store: DraftStore
  ) -> Draft? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      mark(suggestion.threadID, status: "Write a reply first.")
      return nil
    }
    do {
      let context = suggestion.messages.suffix(8).map(\.contextMessage)
      let draft: Draft
      switch suggestion.platform {
      case .imessage:
        draft = try store.createIMessageDraft(
          toHandle: suggestion.handle,
          toHandleName: suggestion.displayName,
          body: trimmed,
          scheduledAt: scheduledAt,
          approveScheduledDraft: approveScheduledDraft,
          contextMessages: context,
          inReplyToThreadID: suggestion.threadID
        )
      case .whatsapp:
        draft = try store.createWhatsAppDraft(
          toHandle: suggestion.handle,
          toHandleName: suggestion.displayName,
          body: trimmed,
          scheduledAt: scheduledAt,
          approveScheduledDraft: approveScheduledDraft,
          contextMessages: context
        )
      }
      if let scheduledAt {
        mark(suggestion.threadID, status: "Scheduled reply queued for \(Self.shortDate(scheduledAt)).")
      } else {
        mark(suggestion.threadID, status: "Reply ready. Hold the bubble to send.")
      }
      DiagnosticsStore.shared.log("dont_ghost.draft_queued", metadata: [
        "scheduled": scheduledAt != nil,
        "approve_scheduled": approveScheduledDraft
      ])
      return draft
    } catch {
      mark(suggestion.threadID, status: "Could not queue reply: \(error.localizedDescription)")
      DiagnosticsStore.shared.log("dont_ghost.draft_queue_failed", metadata: [
        "scheduled": scheduledAt != nil,
        "error_type": String(describing: type(of: error))
      ])
      return nil
    }
  }

  private func mark(_ threadID: Int, status: String) {
    guard let idx = suggestions.firstIndex(where: { $0.threadID == threadID }) else { return }
    suggestions[idx].status = status
  }

  /// Sort by most-recent activity (last message in the thread, any direction).
  /// Owed-replies and follow-ups interleave purely by recency; the kind is a
  /// label, not a rank. Ties break on kind so owed-replies (the higher-signal
  /// "they're waiting on you" case) edge ahead of follow-ups at equal recency.
  nonisolated static func byRecency(_ a: DontGhostSuggestion, _ b: DontGhostSuggestion) -> Bool {
    if a.lastMessageAt != b.lastMessageAt { return a.lastMessageAt > b.lastMessageAt }
    if a.kind != b.kind { return a.kind == .owedReply }
    return a.threadID < b.threadID
  }

  private static func merge(current: [DontGhostSuggestion], cached: [DontGhostSuggestion]) -> [DontGhostSuggestion] {
    var seen = Set<String>()
    var merged: [DontGhostSuggestion] = []
    for suggestion in current + cached {
      guard !seen.contains(suggestion.id) else { continue }
      seen.insert(suggestion.id)
      merged.append(suggestion)
    }
    return merged.sorted(by: byRecency)
  }

  nonisolated static func suggestionsExcludingPendingWork(_ suggestions: [DontGhostSuggestion], drafts: [Draft]) -> [DontGhostSuggestion] {
    let pendingDrafts = drafts.filter { !$0.isSent }
    guard !pendingDrafts.isEmpty, !suggestions.isEmpty else { return suggestions }
    let imessageThreadIDs = Set(pendingDrafts.filter { $0.effectivePlatform == .imessage }.compactMap(\.in_reply_to_thread_id))
    let handles = Set(pendingDrafts.map { canonicalHandle($0.to_handle) }.filter { !$0.isEmpty })
    return suggestions.filter { suggestion in
      if suggestion.platform == .imessage && imessageThreadIDs.contains(suggestion.threadID) { return false }
      let handle = canonicalHandle(suggestion.handle)
      return handle.isEmpty || !handles.contains(handle)
    }
  }

  nonisolated static func suggestionsExcludingStaleIdentityActivity(
    _ suggestions: [DontGhostSuggestion],
    latestActivityByIdentity: [String: Date]
  ) -> [DontGhostSuggestion] {
    var seen = Set<String>()
    return suggestions
      .filter { suggestion in
        let key = contactIdentityKey(displayName: suggestion.displayName, handle: suggestion.handle)
        guard let latest = latestActivityByIdentity[key] else { return true }
        // Anchor on the thread's last message (any direction): if this same
        // person has newer activity in another thread, the surfaced one is
        // stale and gets dropped. Works for both owed-reply (anchor == inbound)
        // and follow-up (anchor == the user's own last message) candidates.
        return latest.timeIntervalSince(suggestion.lastMessageAt) <= 60
      }
      .sorted(by: byRecency)
      .filter { suggestion in
        let key = contactIdentityKey(displayName: suggestion.displayName, handle: suggestion.handle)
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
      }
  }

  // MARK: Candidate selection (kind + age gates)

  /// Age gates, in seconds. Owed-reply gates the THEM-last-message age;
  /// follow-up gates YOUR-last-message age.
  enum SelectionGate {
    /// Owed reply: ignore recent inbound — only surface after a full day of silence.
    static let minInboundAge: TimeInterval = 24 * 60 * 60         // 1 day
    static let maxInboundAge: TimeInterval = 3 * 365 * 86_400     // 3y
    /// Follow-up: do NOT nag about a text they simply haven't answered yet.
    static let minFollowUpAge: TimeInterval = 4 * 86_400          // 4 days
    static let maxFollowUpAge: TimeInterval = 365 * 86_400        // 1 year
  }

  static let owedReplyReason = "Latest message is from them and hasn't been answered."
  static let followUpReason = "You sent last and it's gone quiet — might be worth a check-in."

  /// The result of evaluating a single thread's tail for candidacy.
  struct CandidateSelection: Equatable {
    let kind: DontGhostKind
    let lastInboundAt: Date
    let lastMessageAt: Date
    let reason: String
  }

  /// Decide whether a thread is a Don't Ghost candidate and of which kind.
  /// Pure over the message list + flags so it's unit-testable without SQL.
  ///
  /// Relationship / transactional gates are applied by the caller (the scanner)
  /// for BOTH kinds, unchanged. This function only owns direction + age gating
  /// and the deterministic-mode conservatism for follow-ups.
  ///
  /// - Parameters:
  ///   - aiEnabled: whether an AI classify pass will run afterwards. When false
  ///     (deterministic mode), follow-ups are restricted to saved contacts and a
  ///     tighter silence window to avoid noise.
  ///   - isSavedContact: whether the contact is in the address book / resolved.
  ///   - now: injected clock for tests.
  nonisolated static func candidateSelection(
    messages: [DontGhostMessage],
    aiEnabled: Bool,
    isSavedContact: Bool,
    now: Date = Date()
  ) -> CandidateSelection? {
    guard let last = messages.last else { return nil }

    if !last.fromMe {
      // OWED REPLY: they sent last. Anchor on their last (== overall last).
      let age = now.timeIntervalSince(last.sentAt)
      guard age >= SelectionGate.minInboundAge, age <= SelectionGate.maxInboundAge else { return nil }
      return CandidateSelection(
        kind: .owedReply,
        lastInboundAt: last.sentAt,
        lastMessageAt: last.sentAt,
        reason: owedReplyReason
      )
    }

    // FOLLOW-UP: you sent last (or it mutually went quiet after your message).
    // Anchor the age gate on YOUR last message. Require some prior inbound so
    // there's an actual relationship to reconnect with, not a one-way blast.
    guard let lastInbound = messages.last(where: { !$0.fromMe }) else { return nil }
    let age = now.timeIntervalSince(last.sentAt)
    guard age >= SelectionGate.minFollowUpAge, age <= SelectionGate.maxFollowUpAge else { return nil }
    // No-AI mode no longer hard-restricts follow-ups to saved contacts / a tight
    // window — the deterministic scorer (relationship strength + cadence-aware
    // quiet) decides what actually surfaces, so close threads surface earlier and
    // weak/one-way ones are filtered without a blunt age cutoff.
    return CandidateSelection(
      kind: .followUp,
      lastInboundAt: lastInbound.sentAt,
      lastMessageAt: last.sentAt,
      reason: followUpReason
    )
  }

  nonisolated static func passesRelationshipGate(isSavedContact: Bool, messages: [DontGhostMessage]) -> Bool {
    if isSavedContact { return true }
    let substantive = messages.filter { !isLightweightReaction($0.body) && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let inbound = substantive.filter { !$0.fromMe }.count
    let outbound = substantive.filter(\.fromMe).count
    return inbound >= 2 && outbound >= 2 && substantive.count >= 5
  }

  nonisolated static func isLightweightReaction(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return true }
    let prefixes = [
      "liked ", "loved ", "disliked ", "laughed at ",
      "emphasized ", "questioned ", "reacted ", "reacted with emoji ",
      "removed liked ", "removed loved ", "removed reaction"
    ]
    if prefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
    // Verb-less emoji tapback ("👍 to "…"", "❤️ to "…"") — a reaction rendered as
    // text, not a real message. Anchored at the start so it can't fire mid-message
    // (e.g. "let's go to "Joe's"").
    if trimmed.range(of: #"^[^a-z0-9]{1,6} ?to ["“]"#, options: .regularExpression) != nil { return true }
    return false
  }

  // MARK: Deterministic scorer (the no-API-key arbiter)

  /// A deterministic relevance score for one candidate, used to rank every
  /// suggestion (it replaces the old flat 0.55 confidence) and — in no-API-key
  /// mode — to decide whether a candidate surfaces at all. When an API key is
  /// present the LLM classify pass remains the surface arbiter; this only seeds
  /// confidence/reason. James: "build a deterministic version that doesn't
  /// require an API key" — this is the judgment that stands in for the model.
  struct DontGhostScore: Equatable {
    let value: Double   // 0...1
    let reason: String
    let surfaced: Bool  // value clears the per-kind threshold (no hard suppressor)
  }

  enum ScoreThreshold {
    static let owedReply = 0.50
    static let followUp = 0.62
  }

  // Cue lexicons. Matched with word boundaries so "what" doesn't fire on
  // "whatever". Phrases match as a unit.
  private static let interrogativeCues = ["what", "when", "where", "why", "how", "who", "which", "can you", "could you", "would you", "are you", "did you", "do you", "should we", "you free", "u free"]
  private static let askCues = ["can you", "could you", "let me know", "lmk", "lemme know", "text me", "call me", "send me", "send over", "shoot me"]
  private static let invitationCues = ["want to", "wanna", "let's", "lets", "rsvp", "you free", "this weekend", "tonight", "tomorrow", "dinner", "drinks", "coffee", "grab", "hang", "come over", "you in", "down to", "catch up", "get together"]
  private static let emotionalCues = ["miss you", "thinking of you", "love you", "proud of you", "congrats", "congratulations", "i'm sorry", "im sorry", "are you ok", "you okay", "you ok", "hope you", "how are you", "how've you been", "how have you been", "checking in on you"]

  /// Whole-message closers/acks that need no reply: a bare "ok", "thanks 🙏",
  /// "sounds good", an arrival/status update ("on my way"), or an emoji-only
  /// message. Acks + confirmations + live logistics/status all read as complete.
  private static let closerPhrases: Set<String> = [
    "ok", "okay", "k", "kk", "thanks", "thank you", "ty", "tysm", "thx", "np", "no worries",
    "thanks so much", "thanks a lot", "much appreciated", "appreciate it",
    "sounds good", "sounds great", "sounds perfect", "sg", "great", "perfect", "cool", "ok cool", "nice", "awesome",
    "got it", "gotcha", "will do", "see you then", "see you", "see ya", "cya", "later", "talk later",
    "talk soon", "talk to you later", "ttyl", "see you soon", "see you tomorrow", "see you there",
    "lol", "haha", "hahaha", "lmao", "yep", "yup", "yeah", "word", "bet", "for sure", "done",
    "makes sense", "good to know", "ok thanks", "thank you!", "thanks!", "all good", "good to go",
    // Replies to thanks / acknowledgements — complete, no reply expected.
    "anytime", "you're welcome", "youre welcome", "yw", "no problem", "no prob", "of course",
    "my pleasure", "happy to help", "glad to help", "sure thing",
    // Live logistics / status updates — complete, no reply expected.
    "on my way", "omw", "on the way", "running late", "almost there", "be there soon",
    "be right there", "heading out", "leaving now", "here", "im here", "i'm here", "outside", "almost done"
  ]
  private static let closerWords: Set<String> = [
    "ok", "okay", "k", "kk", "thanks", "ty", "thx", "np", "cool", "great", "perfect", "nice",
    "awesome", "lol", "haha", "lmao", "yep", "yup", "yeah", "word", "bet", "done", "later", "cya"
  ]
  /// Laughter openers: a short message that starts with one reads as a reaction
  /// ("lol that's hilarious"), not something that needs a reply.
  private static let laughterTokens: Set<String> = ["lol", "haha", "hahaha", "hahahaha", "lmao", "lmfao", "heh", "hehe", "lolol", "lmaoo"]
  /// Clause prefixes that mark a complete logistics answer ("address is 123 …").
  /// Kept narrow (answer-shaped) so it can't swallow an imperative like
  /// "address the issue please".
  private static let logisticsPrefixes = ["address is", "the address is", "it's at", "its at"]

  /// True when the body is purely acknowledgement/closer text (no reply expected):
  /// emoji/punctuation only, or every clause (split on , . ! ; ? and newlines) is
  /// a known closer phrase or ≤3 tokens all of which are closer words. Handles
  /// compounds like "sounds good, see you then" and trailing emoji ("thanks 🙏").
  nonisolated static func isPureCloser(_ body: String) -> Bool {
    // A message that asks something is never a pure closer — a question wants an
    // answer (and this lets the sign-off rules below relax safely).
    if body.contains("?") { return false }
    let clauses = body.lowercased().split(whereSeparator: { ",.!;?\n".contains($0) })
    var sawClause = false
    for clause in clauses {
      // Reduce the clause to letter/apostrophe tokens (drops emoji, digits, punct).
      let tokens = clause.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
      if tokens.isEmpty { continue } // emoji- / punctuation-only clause
      // Time/number fragment ("7pm", "at 8", "rm 204") — a logistics scrap, not a
      // clause that needs a reply on its own.
      if clause.contains(where: { $0.isNumber }) && tokens.allSatisfy({ $0.count <= 2 }) { continue }
      sawClause = true
      let cleaned = tokens.joined(separator: " ")
      if closerPhrases.contains(cleaned) { continue }
      if tokens.count <= 3 && tokens.allSatisfy({ closerWords.contains($0) }) { continue }
      // Laughter-led short reaction ("lol that's hilarious") — no reply needed.
      if let first = tokens.first, laughterTokens.contains(first), tokens.count <= 4 { continue }
      // Sign-off ("see you tomorrow at the thing", "catch you later"). Safe to
      // accept any length here because a question already returned false above.
      if cleaned.hasPrefix("see you") || cleaned.hasPrefix("see ya") || cleaned.hasPrefix("catch you") || cleaned.hasPrefix("catch ya") { continue }
      // Complete logistics answer ("address is 123 main st").
      if logisticsPrefixes.contains(where: { cleaned.hasPrefix($0) }) { continue }
      return false // a non-closer clause → a reply is plausibly expected
    }
    // Every clause was a closer (sawClause), or the whole body was emoji/punct.
    return sawClause || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || onlyNonLetters(body)
  }

  nonisolated private static func onlyNonLetters(_ body: String) -> Bool {
    !body.contains { $0.isLetter }
  }

  nonisolated private static func matchesCue(_ text: String, _ cues: [String]) -> Bool {
    for cue in cues {
      let pattern = "\\b" + NSRegularExpression.escapedPattern(for: cue) + "\\b"
      if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
    }
    return false
  }

  /// Content cues in one inbound body → (additive boost, dominant cue key for the
  /// reason string). Each category fires at most once; the highest-weight cue wins.
  nonisolated private static func contentCues(_ body: String) -> (boost: Double, dominant: String?) {
    let t = body.lowercased()
    var contributions: [(key: String, weight: Double)] = []
    if t.contains("?") { contributions.append(("question", 0.30)) }
    if matchesCue(t, emotionalCues) { contributions.append(("emotional", 0.22)) }
    if matchesCue(t, interrogativeCues) { contributions.append(("interrogative", 0.20)) }
    if matchesCue(t, askCues) { contributions.append(("ask", 0.20)) }
    if matchesCue(t, invitationCues) { contributions.append(("invitation", 0.18)) }
    let boost = contributions.reduce(0) { $0 + $1.weight }
    let dominant = contributions.max(by: { $0.weight < $1.weight })?.key
    return (boost, dominant)
  }

  nonisolated private static func substantiveMessages(_ messages: [DontGhostMessage]) -> [DontGhostMessage] {
    messages.filter { !isLightweightReaction($0.body) && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  nonisolated static func scoreCandidate(
    kind: DontGhostKind,
    messages: [DontGhostMessage],
    isSavedContact: Bool,
    now: Date = Date()
  ) -> DontGhostScore {
    switch kind {
    case .owedReply:
      return scoreOwedReply(messages: messages, now: now)
    case .followUp:
      return scoreFollowUp(messages: messages, isSavedContact: isSavedContact, now: now)
    }
  }

  nonisolated private static func scoreOwedReply(messages: [DontGhostMessage], now: Date) -> DontGhostScore {
    guard let inbound = messages.last(where: { !$0.fromMe }) else {
      return DontGhostScore(value: 0, reason: owedReplyReason, surfaced: false)
    }
    // Hard suppressors: a reaction/tapback or a pure ack/closer needs no reply.
    if isLightweightReaction(inbound.body) || isPureCloser(inbound.body) {
      return DontGhostScore(value: 0.15, reason: owedReplyReason, surfaced: false)
    }
    var (boost, dominant) = contentCues(inbound.body)
    // Multiple unanswered inbound in a row → higher social cost to ignore.
    var trailing = 0
    for message in messages.reversed() {
      if message.fromMe { break }
      trailing += 1
    }
    if trailing >= 2 {
      boost += 0.12
      if dominant == nil { dominant = "multi" }
    }
    // Recent high-signal messages outrank stale ones; old still surfaces.
    let ageDays = max(0, now.timeIntervalSince(inbound.sentAt) / 86_400)
    let recency = min(max(1.0 - ageDays / 90.0, 0.4), 1.0)
    // Base == threshold: every non-closer owed reply still surfaces (recall like
    // today), cues raise confidence/rank, closers/reactions fall out (precision).
    let value = min(max(ScoreThreshold.owedReply + boost * recency, 0), 1)
    return DontGhostScore(value: value, reason: owedReason(dominant), surfaced: value >= ScoreThreshold.owedReply)
  }

  nonisolated private static func scoreFollowUp(messages: [DontGhostMessage], isSavedContact: Bool, now: Date) -> DontGhostScore {
    guard let last = messages.last else {
      return DontGhostScore(value: 0, reason: followUpReason, surfaced: false)
    }
    let substantive = substantiveMessages(messages)
    let inbound = substantive.filter { !$0.fromMe }.count
    let outbound = substantive.filter(\.fromMe).count
    // Relationship strength R: volume + two-sidedness + how long the thread has run.
    let vol = min(Double(substantive.count) / 20.0, 1.0)
    let total = inbound + outbound
    let balance = total == 0 ? 0 : 1.0 - Double(abs(inbound - outbound)) / Double(max(total, 1))
    let spanDays = max(0, (messages.last?.sentAt.timeIntervalSince(messages.first?.sentAt ?? now) ?? 0) / 86_400)
    let span = min(spanDays / 60.0, 1.0)
    let savedBonus = isSavedContact ? 0.15 : 0.0
    let r = min(max(0.45 * vol + 0.35 * balance + 0.20 * span + savedBonus, 0), 1)

    // Cadence-aware quiet factor Q: silence relative to the pair's normal rhythm,
    // floored at 4 days so chatty pairs don't trip instantly.
    let typicalGap = averageGap(messages)
    let silence = max(0, now.timeIntervalSince(last.sentAt))
    let q = min(max(silence / max(typicalGap * 6, 4 * 86_400), 0), 1)

    // A last inbound that left things open ("let's catch up soon") nudges it up.
    let openEnded = messages.last(where: { !$0.fromMe }).map { contentCues($0.body).dominant != nil } ?? false
    let openBonus = openEnded ? 0.10 : 0.0

    // Relationship gate: a follow-up should be a real, two-way relationship you
    // haven't already been chasing. Without this, a quiet thread (high Q) drags a
    // thin or one-way thread over the bar on cadence alone.
    //   • need enough substantive history (not a 3-text acquaintance)
    //   • need genuine two-sidedness (not a one-way blast)
    //   • not already nagging (≥3 unanswered trailing messages from you)
    var trailingOutbound = 0
    for message in messages.reversed() {
      if message.fromMe { trailingOutbound += 1 } else { break }
    }
    let relationshipReal = substantive.count >= 5 && balance >= 0.34 && trailingOutbound < 3

    let value = min(max(0.55 * r + 0.45 * q + openBonus, 0), 1)
    return DontGhostScore(
      value: value,
      reason: followUpReasonFor(r: r, openEnded: openEnded),
      surfaced: relationshipReal && value >= ScoreThreshold.followUp
    )
  }

  /// Mean gap (seconds) between consecutive messages in the loaded tail. A very
  /// large fallback for <2 messages so a single message reads as "rarely talk".
  nonisolated private static func averageGap(_ messages: [DontGhostMessage]) -> TimeInterval {
    guard messages.count >= 2 else { return 30 * 86_400 }
    let sorted = messages.map(\.sentAt).sorted()
    var sum: TimeInterval = 0
    for i in 1..<sorted.count { sum += sorted[i].timeIntervalSince(sorted[i - 1]) }
    return sum / Double(sorted.count - 1)
  }

  nonisolated private static func owedReason(_ dominant: String?) -> String {
    switch dominant {
    case "question", "interrogative": return "They asked you something and it's still open."
    case "ask": return "They asked you to do something — still on you."
    case "invitation": return "They floated a plan — worth a quick yes or no."
    case "emotional": return "They reached out personally; a reply would land."
    case "multi": return "They've messaged more than once with no reply."
    default: return owedReplyReason
    }
  }

  nonisolated private static func followUpReasonFor(r: Double, openEnded: Bool) -> String {
    if openEnded { return "They left it open last time — easy to pick back up." }
    if r >= 0.6 { return "You two talk often and it's gone quiet — a check-in would feel natural." }
    return followUpReason
  }

  nonisolated private static func canonicalHandle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      if digits.count >= 10 { return String(digits.suffix(10)) }
      return digits
    }
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }

  nonisolated static func contactIdentityKey(displayName: String, handle: String) -> String {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, canonicalHandle(name).isEmpty {
      let folded = name
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
      return "name:\(folded)"
    }
    let handleKey = canonicalHandle(handle)
    return handleKey.isEmpty ? "handle:\(handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" : "handle:\(handleKey)"
  }

  private func loadCachedResults() {
    let cached = cache.load()
    guard !cached.isEmpty else { return }
    let startedAt = Date()
    DiagnosticsStore.shared.log("dont_ghost.cache_load_started", metadata: [
      "cached_count": cached.count
    ])
    isLoadingCache = true
    status = .loading("Loading cached threads...")
    Task.detached(priority: .utility) {
      do {
        let hydrated = try DontGhostScanner.hydrate(cached)
          .filter { self.dismissals.shouldShow(threadID: $0.threadID, lastMessageKey: $0.lastMessageKey) }
          .sorted(by: Self.byRecency)
        await MainActor.run {
          self.suggestions = hydrated
          self.cache.save(hydrated)
          self.isLoadingCache = false
          self.status = hydrated.isEmpty ? .idle : .ready(Date())
          DiagnosticsStore.shared.log("dont_ghost.cache_load_completed", metadata: [
            "result_count": hydrated.count,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
          ])
        }
      } catch {
        await MainActor.run {
          self.isLoadingCache = false
          self.status = .failed(Self.userFacingError(error))
          DiagnosticsStore.shared.log("dont_ghost.cache_load_failed", metadata: [
            "error_type": String(describing: type(of: error)),
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
          ])
        }
      }
    }
  }

  nonisolated static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  nonisolated static func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
  }

  static func userFacingError(_ error: Error) -> String {
    switch error {
    case DontGhostError.chatDbMissing:
      return "Messages database not found."
    case DontGhostError.sqliteOpen(let message):
      return "Could not read Messages. Check Full Disk Access. \(message)"
    case DontGhostError.sqlitePrepare(let message):
      return "Could not scan Messages. \(message)"
    case DontGhostError.noAPIKey:
      return "Add a Claude or ChatGPT API key in Settings first."
    case DontGhostError.noStyleGuide:
      return "Build Texting Style first."
    case DontGhostError.invalidResponse:
      return "The model returned an unreadable response."
    case let llm as DontGhostLLMClient.APIError:
      return llm.message
    default:
      return error.localizedDescription
    }
  }
}

struct DontGhostDismissalStore {
  private let url: URL

  init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-mcp/dont-ghost-dismissals.json")) {
    self.url = url
  }

  /// The stored value is the last-message timestamp (any direction). For
  /// owed-reply threads that equals the inbound timestamp, so dismissal files
  /// written by older builds (which stored `iso(lastInboundAt)`) keep matching
  /// and continue to suppress those threads. A thread re-surfaces as soon as ANY
  /// new message (inbound or outbound) changes the key.
  func shouldShow(threadID: Int, lastMessageKey: String) -> Bool {
    load()["\(threadID)"] != lastMessageKey
  }

  func dismiss(threadID: Int, lastMessageKey: String) {
    var map = load()
    map["\(threadID)"] = lastMessageKey
    save(map)
  }

  private func load() -> [String: String] {
    guard let data = try? Data(contentsOf: url),
          let map = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return map
  }

  private func save(_ map: [String: String]) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(map)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Best effort. A failed dismissal write should not break the lab.
    }
  }
}

struct DontGhostCachedSuggestion: Codable, Equatable, Identifiable {
  let threadID: Int
  let platform: Platform?
  let displayName: String
  let handle: String
  let lastInboundKey: String
  let lastMessageKey: String
  let kind: DontGhostKind
  let reason: String
  let confidence: Double
  let draftText: String
  let cachedAt: String

  var id: String { "\((platform ?? .imessage).rawValue):\(threadID)" }

  init(
    threadID: Int,
    platform: Platform?,
    displayName: String,
    handle: String,
    lastInboundKey: String,
    lastMessageKey: String,
    kind: DontGhostKind,
    reason: String,
    confidence: Double,
    draftText: String,
    cachedAt: String
  ) {
    self.threadID = threadID
    self.platform = platform
    self.displayName = displayName
    self.handle = handle
    self.lastInboundKey = lastInboundKey
    self.lastMessageKey = lastMessageKey
    self.kind = kind
    self.reason = reason
    self.confidence = confidence
    self.draftText = draftText
    self.cachedAt = cachedAt
  }

  // Backward compatibility: cache rows written before the follow-up feature
  // have no `kind` field. Decode them as `.owedReply` (the only kind that
  // existed) so old caches hydrate cleanly.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    threadID = try c.decode(Int.self, forKey: .threadID)
    platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
    displayName = try c.decode(String.self, forKey: .displayName)
    handle = try c.decode(String.self, forKey: .handle)
    lastInboundKey = try c.decode(String.self, forKey: .lastInboundKey)
    lastMessageKey = try c.decode(String.self, forKey: .lastMessageKey)
    kind = try c.decodeIfPresent(DontGhostKind.self, forKey: .kind) ?? .owedReply
    reason = try c.decode(String.self, forKey: .reason)
    confidence = try c.decode(Double.self, forKey: .confidence)
    draftText = try c.decode(String.self, forKey: .draftText)
    cachedAt = try c.decode(String.self, forKey: .cachedAt)
  }
}

struct DontGhostCacheStore {
  private let url: URL

  init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-mcp/dont-ghost-cache.json")) {
    self.url = url
  }

  func load() -> [DontGhostCachedSuggestion] {
    guard let data = try? Data(contentsOf: url),
          let rows = try? JSONDecoder().decode([DontGhostCachedSuggestion].self, from: data) else {
      return []
    }
    return rows
  }

  func save(_ suggestions: [DontGhostSuggestion]) {
    saveRows(suggestions.map { suggestion in
      DontGhostCachedSuggestion(
        threadID: suggestion.threadID,
        platform: suggestion.platform,
        displayName: suggestion.displayName,
        handle: suggestion.handle,
        lastInboundKey: suggestion.lastInboundKey,
        lastMessageKey: DontGhostController.iso(suggestion.lastMessageAt),
        kind: suggestion.kind,
        reason: suggestion.reason,
        confidence: suggestion.confidence,
        draftText: suggestion.draftText,
        cachedAt: DontGhostController.iso(Date())
      )
    })
  }

  func remove(threadID: Int) {
    saveRows(load().filter { $0.threadID != threadID })
  }

  private func saveRows(_ rows: [DontGhostCachedSuggestion]) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(rows)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Best effort. Cold-starting is better than breaking the lab.
    }
  }
}

// Internal (not private) so the real-data eval harness can pull the candidate
// universe; production access is still only through DontGhostController.
enum DontGhostScanner {
  private static let candidateThreadLimit = 1500
  private static let contextMessageLimit = 32

  static func loadCandidates(aiEnabled: Bool) throws -> [DontGhostSuggestion] {
    let combined = try loadIMessageCandidates(aiEnabled: aiEnabled) + loadWhatsAppCandidates(aiEnabled: aiEnabled)
    return deduplicateCrossPlatform(combined)
  }

  /// Cross-platform deduplication: after combining iMessage + WhatsApp results,
  /// build a single latestActivityByIdentity map from the full set and run the
  /// identity dedup filter so the same person never surfaces twice (once per
  /// platform). Keeps the thread where the person was most recently active.
  private static func deduplicateCrossPlatform(_ suggestions: [DontGhostSuggestion]) -> [DontGhostSuggestion] {
    guard suggestions.count > 1 else { return suggestions }
    var latestByIdentity: [String: Date] = [:]
    for s in suggestions {
      let key = DontGhostController.contactIdentityKey(displayName: s.displayName, handle: s.handle)
      latestByIdentity[key] = max(latestByIdentity[key] ?? .distantPast, s.lastMessageAt)
    }
    return DontGhostController.suggestionsExcludingStaleIdentityActivity(
      suggestions,
      latestActivityByIdentity: latestByIdentity
    )
  }

  private static func loadIMessageCandidates(aiEnabled: Bool) throws -> [DontGhostSuggestion] {
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      throw DontGhostError.chatDbMissing
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
      let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
      if let db { sqlite3_close(db) }
      throw DontGhostError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    let resolver = DontGhostContactResolver.load()
    let latestByIdentity = try latestIMessageActivityByIdentity(db: db, resolver: resolver)
    let chats = try recentOneToOneChats(db: db, resolver: resolver)
    let suggestions: [DontGhostSuggestion] = try chats.compactMap { chat in
      guard !BusinessFilter.looksLikeBusinessHandle(chat.handle),
            !BusinessFilter.looksLikeBusinessName(chat.name) else { return nil }
      let messages = try loadMessages(db: db, chatID: chat.id)
      guard let selection = DontGhostController.candidateSelection(
        messages: messages,
        aiEnabled: aiEnabled,
        isSavedContact: chat.isSavedContact
      ) else { return nil }
      guard DontGhostController.passesRelationshipGate(isSavedContact: chat.isSavedContact, messages: messages) else { return nil }
      guard !looksLikeTransactionalThread(messages) else { return nil }
      let score = DontGhostController.scoreCandidate(kind: selection.kind, messages: messages, isSavedContact: chat.isSavedContact)
      // No-API-key mode: the deterministic scorer is the final surface arbiter.
      // With a key, the LLM classify pass still decides; the score seeds confidence.
      if !aiEnabled, !score.surfaced { return nil }
      return DontGhostSuggestion(
        threadID: chat.id,
        platform: .imessage,
        displayName: chat.name,
        handle: chat.handle,
        lastInboundAt: selection.lastInboundAt,
        lastMessageAt: selection.lastMessageAt,
        messages: messages,
        kind: selection.kind,
        reason: score.reason,
        confidence: score.value
      )
    }
    return DontGhostController.suggestionsExcludingStaleIdentityActivity(
      suggestions,
      latestActivityByIdentity: latestByIdentity
    )
  }

  static func hydrate(_ cached: [DontGhostCachedSuggestion]) throws -> [DontGhostSuggestion] {
    guard !cached.isEmpty else { return [] }
    let imessageRows = cached.filter { ($0.platform ?? .imessage) == .imessage }
    let whatsappRows = cached.filter { $0.platform == .whatsapp }
    let combined = try hydrateIMessage(imessageRows) + hydrateWhatsApp(whatsappRows)
    return deduplicateCrossPlatform(combined)
  }

  private static func hydrateIMessage(_ cached: [DontGhostCachedSuggestion]) throws -> [DontGhostSuggestion] {
    guard !cached.isEmpty else { return [] }
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      throw DontGhostError.chatDbMissing
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
      let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
      if let db { sqlite3_close(db) }
      throw DontGhostError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    let resolver = DontGhostContactResolver.load()
    let latestByIdentity = try latestIMessageActivityByIdentity(db: db, resolver: resolver)
    let suggestions: [DontGhostSuggestion] = try cached.compactMap { row in
      let messages = try loadMessages(db: db, chatID: row.threadID)
      guard let resolved = resolveCachedTail(row, messages: messages) else { return nil }
      let cachedLooksNamed = !looksLikeRawHandleLabel(row.displayName)
      guard DontGhostController.passesRelationshipGate(isSavedContact: resolver.resolve(row.handle) != nil || cachedLooksNamed, messages: messages) else { return nil }
      return DontGhostSuggestion(
        threadID: row.threadID,
        platform: .imessage,
        displayName: row.displayName,
        handle: row.handle,
        lastInboundAt: resolved.lastInboundAt,
        lastMessageAt: resolved.lastMessageAt,
        messages: messages,
        kind: row.kind,
        reason: row.reason,
        confidence: row.confidence,
        draftText: row.draftText,
        status: "Cached from last scan."
      )
    }
    return DontGhostController.suggestionsExcludingStaleIdentityActivity(
      suggestions,
      latestActivityByIdentity: latestByIdentity
    )
  }

  /// Validate a cached row against the live thread tail and re-derive its
  /// anchors. A cached suggestion stays valid only while the thread's last
  /// message is unchanged (matches `row.lastMessageKey`) — as soon as ANY new
  /// message lands, the anchor moves and the cached row is dropped (the fresh
  /// scan will re-evaluate it). Owed-reply rows written by older builds stored
  /// only `lastInboundKey`; for those `lastMessageKey == lastInboundKey`, so the
  /// match still holds.
  private static func resolveCachedTail(
    _ row: DontGhostCachedSuggestion,
    messages: [DontGhostMessage]
  ) -> (lastInboundAt: Date, lastMessageAt: Date)? {
    guard let last = messages.last else { return nil }
    guard DontGhostController.iso(last.sentAt) == row.lastMessageKey else { return nil }
    switch row.kind {
    case .owedReply:
      // Must still be them-last and unanswered.
      guard !last.fromMe else { return nil }
      return (last.sentAt, last.sentAt)
    case .followUp:
      // Must still be you-last with a prior inbound to reconnect with.
      guard last.fromMe, let lastInbound = messages.last(where: { !$0.fromMe }) else { return nil }
      return (lastInbound.sentAt, last.sentAt)
    }
  }

  private static func recentOneToOneChats(db: OpaquePointer, resolver: DontGhostContactResolver) throws -> [(id: Int, name: String, handle: String, isSavedContact: Bool)] {
    let sql = """
      SELECT c.ROWID,
             c.display_name,
             GROUP_CONCAT(DISTINCT h.id),
             COUNT(DISTINCT h.id),
             MAX(m.date)
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE c.style = 45
      GROUP BY c.ROWID
      HAVING COUNT(DISTINCT h.id) = 1
      ORDER BY MAX(m.date) DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw DontGhostError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(candidateThreadLimit))

    var rows: [(id: Int, name: String, handle: String, isSavedContact: Bool)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let chatName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let handlePtr = sqlite3_column_text(stmt, 2) else { continue }
      let handle = String(cString: handlePtr)
      let resolved = resolver.resolve(handle)
      let displayName = resolved ?? chatName
      rows.append((chatID, displayName?.isEmpty == false ? displayName! : handle, handle, resolved != nil))
    }
    return rows
  }

  private static func latestIMessageActivityByIdentity(db: OpaquePointer, resolver: DontGhostContactResolver) throws -> [String: Date] {
    let sql = """
      SELECT h.id, MAX(m.date)
      FROM handle h
      JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
      JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE m.date IS NOT NULL
      GROUP BY h.id
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw DontGhostError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }

    var latest: [String: Date] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let handlePtr = sqlite3_column_text(stmt, 0) else { continue }
      let handle = String(cString: handlePtr)
      let date = imessageDate(sqlite3_column_int64(stmt, 1))
      let displayName = resolver.resolve(handle) ?? handle
      let key = DontGhostController.contactIdentityKey(displayName: displayName, handle: handle)
      if let existing = latest[key] {
        if date > existing { latest[key] = date }
      } else {
        latest[key] = date
      }
    }
    return latest
  }

  private static func loadMessages(db: OpaquePointer, chatID: Int) throws -> [DontGhostMessage] {
    let sql = """
      SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, h.id, m.associated_message_type
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = ?
        AND (
          (m.text IS NOT NULL AND length(trim(m.text)) > 0)
          OR m.attributedBody IS NOT NULL
          OR (m.associated_message_type >= 2000 AND m.associated_message_type <= 3999)
        )
      ORDER BY m.date DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw DontGhostError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(chatID))
    sqlite3_bind_int(stmt, 2, Int32(contextMessageLimit))

    var messages: [DontGhostMessage] = []
    let resolver = DontGhostContactResolver.load()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = sqlite3_column_int64(stmt, 0)
      let sentAt = imessageDate(sqlite3_column_int64(stmt, 1))
      let fromMe = sqlite3_column_int(stmt, 2) == 1
      let textCol = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
      let attributed: Data? = {
        guard let blob = sqlite3_column_blob(stmt, 4) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 4))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
      }()
      let body = bestMessageBody(textCol: textCol, attributedBody: attributed)
        .replacingOccurrences(of: "\u{fffc}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let associatedType = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
      let displayBody = body.isEmpty ? (tapbackFallback(associatedType) ?? "") : body
      guard !displayBody.isEmpty else { continue }
      let senderHandle = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      messages.append(
        DontGhostMessage(
          id: id,
          fromMe: fromMe,
          senderName: fromMe ? "You" : senderHandle.flatMap { resolver.resolve($0) },
          body: displayBody,
          sentAt: sentAt
        )
      )
    }
    return messages.reversed()
  }

  private static func loadWhatsAppCandidates(aiEnabled: Bool) throws -> [DontGhostSuggestion] {
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".whatsapp-mcp/messages.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      return []
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
      let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
      if let db { sqlite3_close(db) }
      throw DontGhostError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    // Thread metadata (names, JIDs, recency) is plaintext, so thread selection
    // stays a direct SQL read. Message BODIES are encrypted at rest, so they
    // load through the daemon's decrypt-on-read RPC (see loadWhatsAppMessages).
    let threads = try recentWhatsAppOneToOneThreads(db: db)
    var suggestions: [DontGhostSuggestion] = []
    for thread in threads {
      guard !thread.isBusiness,
            !BusinessFilter.looksLikeBusinessHandle(thread.jid),
            !BusinessFilter.looksLikeBusinessName(thread.name) else { continue }
      let messages: [DontGhostMessage]
      do {
        messages = try loadWhatsAppMessages(threadJID: thread.jid, displayName: thread.name)
      } catch let error as WhatsAppRPCClient.RPCError where error.isDaemonUnavailable {
        // Daemon down / not installed / peer-auth refused → no decrypt path this
        // pass. Don't fail the (iMessage-inclusive) scan, and never fall back to
        // the encrypted `body` column — just stop collecting WhatsApp candidates.
        return suggestions
      } catch {
        // A single malformed thread response shouldn't sink the whole scan.
        continue
      }
      guard let selection = DontGhostController.candidateSelection(
        messages: messages,
        aiEnabled: aiEnabled,
        isSavedContact: thread.isSavedContact
      ) else { continue }
      guard DontGhostController.passesRelationshipGate(isSavedContact: thread.isSavedContact, messages: messages) else { continue }
      guard !looksLikeTransactionalThread(messages) else { continue }
      let score = DontGhostController.scoreCandidate(kind: selection.kind, messages: messages, isSavedContact: thread.isSavedContact)
      if !aiEnabled, !score.surfaced { continue }
      // Keep the WhatsApp-specific phrasing only for the GENERIC owed-reply reason;
      // the scorer's cue-specific reasons already read naturally for either platform.
      let reason = (selection.kind == .owedReply && score.reason == DontGhostController.owedReplyReason)
        ? "Latest WhatsApp message is from them and hasn't been answered."
        : score.reason
      suggestions.append(DontGhostSuggestion(
        threadID: stableThreadID("whatsapp:\(thread.jid)"),
        platform: .whatsapp,
        displayName: thread.name,
        handle: thread.jid,
        lastInboundAt: selection.lastInboundAt,
        lastMessageAt: selection.lastMessageAt,
        messages: messages,
        kind: selection.kind,
        reason: reason,
        confidence: score.value
      ))
    }
    return suggestions
  }

  private static func hydrateWhatsApp(_ cached: [DontGhostCachedSuggestion]) throws -> [DontGhostSuggestion] {
    guard !cached.isEmpty else { return [] }
    // Bodies come from the daemon's decrypt-on-read RPC (the encrypted on-disk
    // column would hand back garbage), so there's no SQLite handle to open here.
    let resolver = DontGhostContactResolver.load()
    var result: [DontGhostSuggestion] = []
    for row in cached {
      let messages: [DontGhostMessage]
      do {
        messages = try loadWhatsAppMessages(threadJID: row.handle, displayName: row.displayName)
      } catch let error as WhatsAppRPCClient.RPCError where error.isDaemonUnavailable {
        // No decrypt path this pass — stop hydrating WhatsApp rows rather than
        // fail (see loadWhatsAppCandidates). Never read the encrypted column.
        return result
      } catch {
        continue
      }
      guard let resolved = resolveCachedTail(row, messages: messages) else { continue }
      guard DontGhostController.passesRelationshipGate(isSavedContact: resolver.resolve(row.handle) != nil, messages: messages) else { continue }
      result.append(DontGhostSuggestion(
        threadID: row.threadID,
        platform: .whatsapp,
        displayName: row.displayName,
        handle: row.handle,
        lastInboundAt: resolved.lastInboundAt,
        lastMessageAt: resolved.lastMessageAt,
        messages: messages,
        kind: row.kind,
        reason: row.reason,
        confidence: row.confidence,
        draftText: row.draftText,
        status: "Cached from last scan."
      ))
    }
    return result
  }

  private static func recentWhatsAppOneToOneThreads(db: OpaquePointer) throws -> [(jid: String, name: String, isBusiness: Bool, isSavedContact: Bool)] {
    let sql = """
      SELECT t.thread_jid,
             t.display_name,
             c.display_name,
             c.push_name,
             COALESCE(c.is_business, 0)
      FROM threads t
      LEFT JOIN contacts c ON c.jid = t.thread_jid
      WHERE t.is_group = 0
      ORDER BY t.last_message_ts DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw DontGhostError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(candidateThreadLimit))

    let resolver = DontGhostContactResolver.load()
    var rows: [(jid: String, name: String, isBusiness: Bool, isSavedContact: Bool)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let jidPtr = sqlite3_column_text(stmt, 0) else { continue }
      let jid = String(cString: jidPtr)
      let threadName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
      let contactName = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let pushName = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
      let resolved = resolver.resolve(jid)
      let cleanContactName = contactName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      let name = [
        resolved,
        contactName,
        threadName,
        pushName,
        jid
      ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }.first ?? jid
      rows.append((jid, name, sqlite3_column_int(stmt, 4) == 1, resolved != nil || cleanContactName != nil))
    }
    return rows
  }

  /// Load a WhatsApp thread's recent messages with DECRYPTED bodies.
  ///
  /// Message content is encrypted at rest: `~/.whatsapp-mcp/messages.db`'s
  /// `body` column holds AES-256-GCM ciphertext (#81) and only the daemon holds
  /// the Keychain key. Reading the column directly (which the Swift side must
  /// never do) hands back byte-garbage — exactly the bug that surfaced here. We
  /// fetch through the daemon's decrypt-on-read `getThread` RPC instead, the
  /// same path the Messages tab uses. Throws `WhatsAppRPCClient.RPCError` when
  /// the daemon is unreachable; the caller decides whether that's fatal.
  private static func loadWhatsAppMessages(threadJID: String, displayName: String) throws -> [DontGhostMessage] {
    // The daemon applies its limit to ALL messages (media/system included),
    // whereas we only want the most-recent text messages. Fetch with margin so
    // attachment-heavy threads still yield a full text window after filtering,
    // then keep the most-recent `contextMessageLimit` text messages.
    let decrypted = try WhatsAppRPCClient.getThreadMessagesSync(
      threadJID: threadJID,
      limit: contextMessageLimit * 2
    )
    let resolver = DontGhostContactResolver.load()
    // Daemon returns most-recent-first.
    var messages: [DontGhostMessage] = []
    for m in decrypted {
      // Belt-and-suspenders: the daemon decrypts content, but if a body ever
      // still reads as raw ciphertext we drop it rather than surface garbage.
      guard let body = sanitizedWhatsAppBody(m.body) else { continue }
      messages.append(
        DontGhostMessage(
          id: Int64(stablePositiveID(m.messageID)),
          fromMe: m.fromMe,
          senderName: m.fromMe ? "You" : (m.senderJID.flatMap { resolver.resolve($0) } ?? displayName),
          body: body,
          sentAt: Date(timeIntervalSince1970: Double(m.ts) / 1000.0)
        )
      )
    }
    // Keep the most-recent N text messages, then flip to chronological order
    // (the scorer + context bubbles read oldest-to-newest).
    return Array(messages.prefix(contextMessageLimit)).reversed()
  }

  /// Clean a WhatsApp body and reject anything that still reads as undecodable
  /// byte-garbage. Strips the object-replacement marker WhatsApp uses for inline
  /// attachments, trims whitespace, then drops the message (returns nil) when the
  /// remainder is empty or `looksUndecodable`.
  static func sanitizedWhatsAppBody(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let cleaned = raw
      .replacingOccurrences(of: "\u{fffc}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, !looksUndecodable(cleaned) else { return nil }
    return cleaned
  }

  /// Heuristic: does this string look like raw bytes misread as text rather than
  /// real message content? Ciphertext read as UTF-8 surfaces as a run of Unicode
  /// replacement characters (U+FFFD) plus C0/C1 control bytes. Genuine messages —
  /// including emoji-only or non-Latin ones — decode to valid scalars and carry
  /// essentially no U+FFFD or control characters. We flag a string when those
  /// "bad" scalars make up a meaningful fraction of it (≥15%).
  static func looksUndecodable(_ s: String) -> Bool {
    let scalars = s.unicodeScalars
    guard !scalars.isEmpty else { return false }
    var bad = 0
    for u in scalars {
      if u == "\u{fffd}" {
        bad += 1
      } else if (u.value < 0x20 && u != "\t" && u != "\n" && u != "\r")
                  || (u.value >= 0x7f && u.value <= 0x9f) {
        bad += 1
      }
    }
    return Double(bad) / Double(scalars.count) >= 0.15
  }

  // Business handle/name detection lives in the shared `BusinessFilter` now (the
  // Swift twin of business.ts), so Don't Ghost and Severance recognize the same
  // businesses. Don't Ghost adds its own CONTENT-based layer below
  // (`looksLikeTransactionalThread`) for businesses on a plain number with a
  // person-ish name, which needs message bodies the metadata-only surfaces lack.

  private static func looksLikeRawHandleLabel(_ label: String) -> Bool {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return true }
    if trimmed.contains("@") { return true }
    if trimmed.hasPrefix("+") { return true }
    return trimmed.filter(\.isNumber).count >= 5
  }

  // Internal (not private) so the table-driven unit tests can exercise the
  // transactional filter directly without going through SQL.
  static func looksLikeTransactionalThread(_ messages: [DontGhostMessage]) -> Bool {
    let inbound = messages.filter { !$0.fromMe }
    guard !inbound.isEmpty else { return false }
    let joined = inbound.map(\.body).joined(separator: " ").lowercased()
    let transactional = [
      "verification code", "security code", "one-time code", "otp", "receipt",
      "order", "delivered", "delivery", "arriving", "appointment", "confirmation",
      "confirmed", "reservation", "unsubscribe", "stop to opt out", "reply stop",
      "billing", "payment", "invoice", "tracking", "package", "password reset"
    ]
    let hits = transactional.filter { joined.contains($0) }.count
    if hits >= 2 { return true }
    let numericHeavy = inbound.filter { msg in
      let chars = Array(msg.body)
      let digits = chars.filter(\.isNumber).count
      return chars.count > 0 && Double(digits) / Double(chars.count) > 0.25
    }.count
    if numericHeavy >= max(2, inbound.count / 2) { return true }
    // Content-based automation detector — catches reminders from a plain phone
    // number with no saved business name (e.g. One Medical on a 415 line) that
    // the handle/name business filters and the keyword count above all miss.
    return looksLikeAutomatedInbound(inbound)
  }

  // Decisive automation phrases: any one in an inbound body marks the thread
  // automated on its own. These calls-to-action / footers effectively never
  // appear in genuine person-to-person texts.
  private static let decisiveAutomationPhrases = [
    "do not reply", "please do not reply", "this is an automated", "automated message",
    "automated reminder", "reply stop", "text stop", "to unsubscribe", "to opt out",
    "to opt-out", "out for delivery", "one-time passcode", "one time passcode",
    "std msg", "msg & data", "message and data rates"
  ]

  // Automation SUBJECT nouns: what a templated transactional message is about.
  // Only load-bearing when paired with an instruction cue below (or repeated in
  // a near-identical template), so a lone mention by a real person is harmless.
  private static let automationSubjectCues = [
    "appointment", "appt", "reservation", "your order", "order #", "order number",
    "delivery", "package", "tracking number", "verification", "passcode",
    "security code", "confirmation code", "your code", "payment", "invoice",
    "amount due", "balance due", "past due", "prescription", "refill", "booking",
    "checked in", "check-in", "your visit", "your account"
  ]

  /// True when an inbound message carries a templated automation INSTRUCTION —
  /// the "Reply Y", "To Reschedule:", "click the link" call-to-action shape that
  /// a friend essentially never uses. The `reply <token>` form is matched with a
  /// trailing word boundary so it can't fire on "reply your thoughts".
  private static func hasAutomationInstruction(_ t: String) -> Bool {
    if t.range(of: #"\breply (y|yes|1|2|3)\b"#, options: .regularExpression) != nil { return true }
    let phrases = [
      "to confirm:", "to reschedule:", "to cancel:", "to confirm reply",
      "to reschedule reply", "to cancel reply", "reply to confirm", "confirm or reschedule",
      "click here", "tap here", "click the link", "tap the link", "follow the link"
    ]
    return phrases.contains { t.contains($0) }
  }

  /// Conservative content-based automated/transactional detector. Tuned for
  /// PRECISION — the user is recall-favoring and would rather see-and-dismiss a
  /// borderline real thread than have it silently filtered, so every path here
  /// demands automation-specific corroboration:
  ///   • a single decisive footer/CTA ("Do not reply", "Reply STOP"), OR
  ///   • one inbound that pairs a templated instruction ("Reply Y",
  ///     "To Reschedule:") with a transactional subject ("appointment"), OR
  ///   • a near-identical templated reminder repeated across the thread.
  static func looksLikeAutomatedInbound(_ inbound: [DontGhostMessage]) -> Bool {
    var markedTemplates: [String] = []   // normalized bodies that carried a marker
    for message in inbound {
      let t = message.body.lowercased()
      if decisiveAutomationPhrases.contains(where: { t.contains($0) }) { return true }
      let hasInstruction = hasAutomationInstruction(t)
      let hasSubject = automationSubjectCues.contains { t.contains($0) }
      if hasInstruction && hasSubject { return true }
      if hasInstruction || hasSubject { markedTemplates.append(normalizedTemplate(message.body)) }
    }
    // A real person does not resend the same long message verbatim; an automated
    // reminder does (only the time/date varies, which normalization strips).
    let longTemplates = markedTemplates.filter { $0.count >= 24 }
    for i in longTemplates.indices {
      for j in longTemplates.indices where j > i && longTemplates[i] == longTemplates[j] {
        return true
      }
    }
    return false
  }

  /// Normalize a body for template-equality: lowercase, drop digits and
  /// punctuation, collapse whitespace — so two otherwise-identical reminders
  /// that differ only in their time/date compare equal.
  private static func normalizedTemplate(_ body: String) -> String {
    let kept = body.lowercased().map { ch -> Character in
      (ch.isLetter || ch.isWhitespace) ? ch : " "
    }
    return String(kept).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private static func bestMessageBody(textCol: String?, attributedBody: Data?) -> String {
    if let textCol, !textCol.isEmpty { return textCol }
    return decodeAttributedBody(attributedBody) ?? ""
  }

  private static func tapbackFallback(_ associatedMessageType: Int?) -> String? {
    guard let associatedMessageType,
          associatedMessageType >= 2000,
          associatedMessageType <= 3999 else { return nil }
    let removed = associatedMessageType >= 3000
    let base = removed ? associatedMessageType - 1000 : associatedMessageType
    let label: String
    switch base {
    case 2000: label = "Loved"
    case 2001: label = "Liked"
    case 2002: label = "Disliked"
    case 2003: label = "Laughed at"
    case 2004: label = "Emphasized"
    case 2005: label = "Questioned"
    case 2006: label = "Reacted with emoji"
    default: label = "Reacted"
    }
    return removed ? "Removed \(label.lowercased()) reaction" : "\(label) a message"
  }

  private static func decodeAttributedBody(_ data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }
    let bytes = [UInt8](data)
    let marker = Array("NSString".utf8)
    guard let markerIdx = bytes.firstRange(of: marker)?.lowerBound else { return nil }
    var cursor = markerIdx + marker.count
    while cursor < bytes.count - 1 {
      if bytes[cursor] == 0x01 && bytes[cursor + 1] == 0x2b {
        cursor += 2
        break
      }
      cursor += 1
    }
    guard cursor < bytes.count else { return nil }
    let first = bytes[cursor]
    cursor += 1
    let length: Int
    if first < 0x80 {
      length = Int(first)
    } else if first == 0x81 {
      guard cursor + 2 <= bytes.count else { return nil }
      length = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
      cursor += 2
    } else if first == 0x82 {
      guard cursor + 4 <= bytes.count else { return nil }
      length = Int(bytes[cursor])
        | (Int(bytes[cursor + 1]) << 8)
        | (Int(bytes[cursor + 2]) << 16)
        | (Int(bytes[cursor + 3]) << 24)
      cursor += 4
    } else {
      return nil
    }
    guard length > 0, cursor + length <= bytes.count else { return nil }
    return String(data: Data(bytes[cursor..<(cursor + length)]), encoding: .utf8)?
      .trimmingCharacters(in: .controlCharacters)
  }

  private static func imessageDate(_ raw: Int64) -> Date {
    if abs(raw) > 10_000_000_000_000 {
      return Date(timeIntervalSince1970: Double(raw) / 1_000_000_000.0 + 978_307_200.0)
    }
    if abs(raw) > 100_000_000 {
      return Date(timeIntervalSince1970: Double(raw) + 978_307_200.0)
    }
    return Date(timeIntervalSince1970: Double(raw))
  }

  private static func stableThreadID(_ value: String) -> Int {
    -stablePositiveID(value)
  }

  private static func stablePositiveID(_ value: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Int(hash & 0x3fff_ffff)
  }
}

private struct DontGhostContactResolver {
  private let handles: [String: String]

  static func load() -> DontGhostContactResolver {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-mcp/contacts-cache.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let handles = json["handles"] as? [String: String] else {
      return DontGhostContactResolver(handles: [:])
    }
    return DontGhostContactResolver(handles: handles)
  }

  func resolve(_ handle: String) -> String? {
    let key = canonical(handle)
    guard !key.isEmpty,
          let name = handles[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    return name
  }

  private func canonical(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      if digits.count >= 10 { return String(digits.suffix(10)) }
      return digits
    }
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }
}

struct DontGhostLLMResponseParser {
  struct ThreadDecision {
    let id: Int
    let shouldSurface: Bool
    let reason: String
    let confidence: Double

    /// Legacy alias: the field was `shouldReply` before follow-ups existed.
    var shouldReply: Bool { shouldSurface }
  }

  static func parseThreadDecisions(_ text: String) -> [ThreadDecision]? {
    guard let root = jsonObject(from: text),
          let rows = root["threads"] as? [[String: Any]] else { return nil }
    let parsed: [ThreadDecision] = rows.compactMap { row in
      // Accept both the new `should_surface` and the legacy `should_reply` key.
      guard let id = row["id"] as? Int,
            let shouldSurface = (row["should_surface"] as? Bool) ?? (row["should_reply"] as? Bool) else { return nil }
      return ThreadDecision(
        id: id,
        shouldSurface: shouldSurface,
        reason: (row["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Needs a reply.",
        confidence: row["confidence"] as? Double ?? 0.7
      )
    }
    // Tolerate individual malformed rows so one flaky row from a nondeterministic
    // model doesn't fail the entire scan — drop the bad row, keep the good ones.
    // But if the model returned rows and *none* were usable, treat the whole
    // response as invalid (the caller throws). An empty "threads" array stays
    // valid: it legitimately means "none of these need a reply."
    if !rows.isEmpty && parsed.isEmpty { return nil }
    return parsed
  }

  private static func jsonObject(from text: String) -> [String: Any]? {
    for candidate in jsonCandidates(from: text) {
      guard let data = candidate.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
      }
      return root
    }
    return nil
  }

  private static func jsonCandidates(from text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates: [String] = [trimmed]

    var searchStart = trimmed.startIndex
    while let fenceStart = trimmed[searchStart...].range(of: "```")?.lowerBound {
      guard let contentStart = trimmed[fenceStart...].firstIndex(of: "\n") else { break }
      let bodyStart = trimmed.index(after: contentStart)
      guard let fenceEnd = trimmed[bodyStart...].range(of: "```")?.lowerBound else { break }
      candidates.append(String(trimmed[bodyStart..<fenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines))
      searchStart = trimmed.index(fenceEnd, offsetBy: 3, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
    }

    if let firstBrace = trimmed.firstIndex(of: "{"),
       let lastBrace = trimmed.lastIndex(of: "}"),
       firstBrace <= lastBrace {
      candidates.append(String(trimmed[firstBrace...lastBrace]))
    }

    var seen = Set<String>()
    return candidates.filter { candidate in
      guard !candidate.isEmpty, !seen.contains(candidate) else { return false }
      seen.insert(candidate)
      return true
    }
  }
}

struct DontGhostLLMClient {
  struct APIError: Error {
    let message: String
  }

  private static let classificationBatchSize = 50

  let provider: TextingVoiceProvider
  let apiKey: String
  let modelID: String
  var recorder: (any AIUsageRecording)? = nil
  /// All batch calls in one classify() run share this id so the Usage pane can
  /// roll them up into a single "scan".
  var runID: UUID? = nil

  static func available(recorder: (any AIUsageRecording)? = nil, runID: UUID? = nil) -> DontGhostLLMClient? {
    guard let selection = LabModelPreferences.clientSelection(for: .dontGhost) else { return nil }
    return DontGhostLLMClient(provider: selection.provider, apiKey: selection.apiKey, modelID: selection.modelID, recorder: recorder, runID: runID)
  }

  func classify(_ candidates: [DontGhostSuggestion]) async throws -> [DontGhostSuggestion] {
    guard !candidates.isEmpty else { return [] }
    var classified: [DontGhostSuggestion] = []
    var offset = 0
    while offset < candidates.count {
      let end = min(offset + Self.classificationBatchSize, candidates.count)
      classified.append(contentsOf: try await classifyBatch(Array(candidates[offset..<end])))
      offset = end
    }
    return classified
  }

  private func classifyBatch(_ batch: [DontGhostSuggestion]) async throws -> [DontGhostSuggestion] {
    let payload = batch.map { suggestion in
      [
        "id": suggestion.threadID,
        "person": suggestion.displayName,
        "kind": suggestion.kind == .owedReply ? "owed_reply" : "follow_up",
        "last_inbound_at": DontGhostController.iso(suggestion.lastInboundAt),
        "last_message_at": DontGhostController.iso(suggestion.lastMessageAt),
        "messages": suggestion.messages.suffix(8).map {
          [
            "from": $0.fromMe ? "me" : "them",
            "sent_at": DontGhostController.iso($0.sentAt),
            "body": $0.body
          ]
        }
      ] as [String: Any]
    }
    let prompt = """
    You help the user keep relationships they care about from quietly going cold — without nagging anyone.

    A deterministic local pass already removed obvious transactional/business threads and tagged each thread with a "kind" (just context):
      - "owed_reply": the OTHER person sent the last substantive message.
      - "follow_up": the USER sent last, or it mutually went quiet.

    A thread is worth surfacing when a nudge would be worthwhile — and a "nudge" is TWO different things, BOTH of which count:
      1) a reply the user still owes — a question, invitation, emotional bid, ask, or a message where silence reads as dropping the ball; OR
      2) a proactive follow-up / re-ping that would be welcome — a warm relationship that has gone quiet, a real but stalled plan worth reviving, a life update worth circling back on (a new baby, a new job, a move, a health thing, a trip), or an open thought that's easy to pick back up.

    CRUCIAL: a conversation reaching a natural pause, the last message being a "complete" thought or an acknowledgement, or the USER having sent last are NOT reasons to skip — those are exactly the moments when a good follow-up keeps a relationship alive. Judge the whole thread and the relationship, not just the final message. "This concluded" and "this is worth a nudge" are SEPARATE questions; a concluded conversation with someone the user cares about is a prime follow-up.

    Only set should_surface FALSE when a nudge would genuinely misfire:
      - the thread is purely transactional or a closed one-off (logistics fully handled, a favor done) with no ongoing relationship to tend;
      - a lone reaction / emoji / quick acknowledgement on an otherwise thin, low-signal thread (e.g. a one-off "happy birthday" → "thanks");
      - a weak or one-directional relationship where a check-in would feel out of the blue;
      - the user has ALREADY sent several unanswered follow-ups (pinging again would read as nagging);
      - the content is unreadable / can't be assessed.

    When you are torn between "this naturally concluded" and "this is worth a nudge," PREFER surfacing it: the user dismisses in one tap, but a quietly-dropped relationship is the costlier miss.

    Write a short "reason" for why a nudge is worth it (the owed reply, or the kind of follow-up). Return strict JSON only:
    {"threads":[{"id":123,"should_surface":true,"reason":"short reason","confidence":0.0}]}

    Threads:
    \(Self.json(payload))
    """
    let text = try await complete(prompt: prompt, maxTokens: 2500)
    guard let rows = DontGhostLLMResponseParser.parseThreadDecisions(text) else {
      throw DontGhostError.invalidResponse
    }
    var byID: [Int: DontGhostLLMResponseParser.ThreadDecision] = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    return batch.compactMap { candidate in
      guard let row = byID.removeValue(forKey: candidate.threadID), row.shouldSurface else { return nil }
      var updated = candidate
      updated.reason = row.reason
      updated.confidence = row.confidence
      return updated
    }
  }

  private func complete(prompt: String, maxTokens: Int) async throws -> String {
    switch provider {
    case .anthropic:
      return try await anthropic(prompt: prompt, maxTokens: maxTokens)
    case .openAI:
      return try await openAI(prompt: prompt, maxTokens: maxTokens)
    }
  }

  private func anthropic(prompt: String, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "max_tokens": maxTokens,
      "system": "Return JSON only. You help draft text replies but never send them.",
      "messages": [["role": "user", "content": prompt]]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "Claude request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]] else { throw DontGhostError.invalidResponse }
    AIUsageReporter.report(recorder, lab: .dontGhost, provider: provider, modelID: modelID, responseRoot: root, runID: runID)
    return content.compactMap { $0["text"] as? String }.joined()
  }

  private func openAI(prompt: String, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "max_output_tokens": maxTokens,
      "input": [
        ["role": "developer", "content": "Return JSON only. You help draft text replies but never send them."],
        ["role": "user", "content": prompt]
      ]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "ChatGPT request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DontGhostError.invalidResponse
    }
    AIUsageReporter.report(recorder, lab: .dontGhost, provider: provider, modelID: modelID, responseRoot: root, runID: runID)
    if let text = root["output_text"] as? String { return text }
    if let output = root["output"] as? [[String: Any]] {
      return output.compactMap { item -> String? in
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.joined()
      }.joined()
    }
    throw DontGhostError.invalidResponse
  }

  private func errorMessage(data: Data, fallback: String) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return fallback
  }

  private static func json(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "[]" }
    return string
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
