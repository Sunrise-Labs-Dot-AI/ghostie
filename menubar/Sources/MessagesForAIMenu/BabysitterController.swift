import Foundation

@MainActor
final class BabysitterController: ObservableObject {
  @Published var statusMessage: String?
  @Published var errorMessage: String?

  /// Re-entrancy guard: stageNextAsk suspends at the off-main chat.db
  /// resolve, so a double-tap could otherwise interleave two stagings of the
  /// same outreach and write two draft files.
  private var isStagingAsk = false

  let store: BabysitterStore

  init(store: BabysitterStore) {
    self.store = store
  }

  /// Persisted into the draft JSON as the provenance label, so spell it with
  /// the shipping product name (the app is being renamed Ghostie this
  /// release — drafts written today should already be born right).
  static let draftSourceLabel = "Ghostie Babysitter"

  @discardableResult
  func stageNextAsk(draftStore: DraftStore) async -> Draft? {
    guard !isStagingAsk else { return nil }
    isStagingAsk = true
    defer { isStagingAsk = false }
    do {
      let prepared = try store.prepareNextOutreach()
      let request = prepared.request
      let outreach = prepared.outreach
      let profile = prepared.profile
      guard let startsAt = BabysitterStore.parseISO(request.startsAt),
            let endsAt = BabysitterStore.parseISO(request.endsAt) else {
        throw BabysitterStoreError.invalidDateRange
      }
      let body = BabysitterMessageTemplate.invitation(
        sitterName: profile.contact.name,
        startsAt: startsAt,
        endsAt: endsAt,
        note: request.note,
        partnerIncluded: request.partner != nil
      )
      let target: BabysitterMessageTarget
      let draft: Draft
      if let partner = request.partner {
        // Resolving the exact sitter+partner chat reads chat.db — keep that
        // off the MainActor so "Stage Ask" can't beachball the UI on a big
        // Messages history.
        let group = try await Self.resolveGroupTarget(sitter: profile, partner: partner)
        target = BabysitterMessageTarget(
          sitterID: profile.id,
          sitterHandle: profile.displayHandle,
          partner: partner,
          imessageGroup: group
        )
        draft = try draftStore.createIMessageGroupDraft(
          group: group,
          body: body,
          source: Self.draftSourceLabel
        )
      } else {
        target = BabysitterMessageTarget(
          sitterID: profile.id,
          sitterHandle: profile.displayHandle,
          partner: nil,
          imessageGroup: nil
        )
        draft = try draftStore.createIMessageDraft(
          toHandle: profile.displayHandle,
          toHandleName: profile.contact.name,
          body: body,
          source: Self.draftSourceLabel
        )
      }
      try store.recordDraft(
        requestID: request.id,
        outreachID: outreach.id,
        draftID: draft.id,
        target: target
      )
      statusMessage = "Staged an ask for \(profile.contact.name)."
      errorMessage = nil
      return draft
    } catch {
      errorMessage = String(describing: error)
      statusMessage = nil
      return nil
    }
  }

  /// chat.db lookup off the MainActor; the policy validation inside
  /// makeTarget is pure and the resolver opens its own read-only connection.
  private nonisolated static func resolveGroupTarget(
    sitter: BabysitterProfile,
    partner: BabysitterContactSnapshot
  ) async throws -> IMessageGroupDraftTarget {
    try await Task.detached(priority: .userInitiated) {
      try IMessageGroupTargetPolicy.makeTarget(sitter: sitter, partner: partner)
    }.value
  }

  func reconcileSentDrafts(_ drafts: [Draft], now: Date = Date()) {
    let sentDrafts = drafts.filter(\.isSent)
    guard !sentDrafts.isEmpty else { return }
    let byID = Dictionary(uniqueKeysWithValues: sentDrafts.map { ($0.id, $0) })
    guard let request = store.activeRequest else { return }
    for outreach in request.outreaches where outreach.sentAt == nil {
      guard let draftID = outreach.draftID,
            let draft = byID[draftID],
            let sentAt = draft.sentDate else { continue }
      store.markOutreachSent(draftID: draftID, sentAt: sentAt, now: now)
    }
  }

  func checkTimeouts(now: Date = Date()) {
    guard let request = store.activeRequest, request.status == .waiting else { return }
    for outreach in request.outreaches where outreach.status == .waiting {
      guard let deadline = outreach.deadlineAt.flatMap(BabysitterStore.parseISO),
            deadline <= now else { continue }
      try? store.recordOutcome(requestID: request.id, outreachID: outreach.id, outcome: .timedOut, resolvedAt: now)
      statusMessage = "That ask timed out. The next babysitter is ready to stage."
      return
    }
  }

  func mark(outreach: BabysitterOutreach, outcome: BabysitterOutcome) {
    guard let request = store.activeRequest else { return }
    do {
      try store.recordOutcome(requestID: request.id, outreachID: outreach.id, outcome: outcome)
      errorMessage = nil
      switch outcome {
      case .accepted: statusMessage = "Confirmed. Babysitter stopped the waterfall."
      case .declined, .timedOut: statusMessage = "Recorded. The next babysitter is ready to stage."
      case .needsUser: statusMessage = "Paused for review."
      case .cancelled: statusMessage = "Request cancelled."
      case .asked: statusMessage = nil
      }
    } catch {
      errorMessage = String(describing: error)
    }
  }

  func cancelActiveRequest() {
    do {
      try store.cancelActiveRequest()
      statusMessage = "Request cancelled."
      errorMessage = nil
    } catch {
      errorMessage = String(describing: error)
    }
  }
}
