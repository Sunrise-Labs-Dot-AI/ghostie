import Foundation

/// The decision a controller acts on before issuing a BYOK AI call.
enum AIBudgetDecision: Equatable {
  /// Under budget — proceed silently.
  case allow
  /// Approaching the cap — proceed, but the UI should warn. `pct` is the
  /// fraction of the monthly cap that would be reached after this call.
  case warn(pct: Double)
  /// At/over the cap with enforcement on — do not make the call. `remainingUSD`
  /// is what's left under the cap (clamped at 0).
  case block(remainingUSD: Double)
}

/// Pure budget evaluation (issue #145). The controller computes month-to-date
/// estimated spend from `AIUsageLedger` and the estimated cost of the next call
/// (`AIUsageEstimate`), then asks the gate whether to proceed. No cap set →
/// always `.allow`. Fail-closed: with `enforce` on, a call is blocked once the
/// cap is reached OR if this call's estimate would push spend over it — the
/// "no surprise AI bills" guarantee. With `enforce` off the cap is advisory
/// (warnings only, never blocks).
enum AIBudgetGate {
  static func evaluate(
    monthToDateUSD: Double,
    estimatedNextCallUSD: Double,
    budget: AIUsageBudget
  ) -> AIBudgetDecision {
    guard let cap = budget.monthlyCapUSD, cap > 0 else { return .allow }

    let nextCall = max(0, estimatedNextCallUSD)
    let projected = monthToDateUSD + nextCall
    let remaining = max(0, cap - monthToDateUSD)

    if budget.enforce, monthToDateUSD >= cap || projected > cap {
      return .block(remainingUSD: remaining)
    }

    let projectedPct = projected / cap
    if let firstWarn = budget.warnThresholds.sorted().first, projectedPct >= firstWarn {
      return .warn(pct: projectedPct)
    }
    return .allow
  }
}

/// Main-actor convenience the controllers call right before issuing a BYOK call.
/// Resolves the lab's current selection, evaluates the gate against month-to-date
/// spend, and on `.block` records a `blockedByBudget` event and returns false so
/// the controller can skip the call. Returns true (proceed) when there's no
/// ledger, no key/selection, or the call is within budget.
@MainActor
enum AIBudgetPrecheck {
  static func allow(lab: AILab, ledger: AIUsageLedger?) -> Bool {
    guard let ledger,
          ledger.budget.monthlyCapUSD != nil,
          let selection = LabModelPreferences.clientSelection(for: lab) else { return true }
    let estimate = AIUsageEstimate.estimatedCostUSD(
      lab: lab, provider: selection.provider, modelID: selection.modelID
    ) ?? 0
    let decision = AIBudgetGate.evaluate(
      monthToDateUSD: ledger.monthToDateUSD(),
      estimatedNextCallUSD: estimate,
      budget: ledger.budget
    )
    if case .block = decision {
      ledger.record(
        lab: lab, provider: selection.provider, modelID: selection.modelID,
        inputTokens: nil, outputTokens: nil, status: .blockedByBudget, runID: nil
      )
      return false
    }
    return true
  }

  /// User-facing copy for the blocked state, shared across labs.
  static let blockedMessage = "Monthly AI budget reached. Raise or pause your cap in the Usage tab to keep going."
}
