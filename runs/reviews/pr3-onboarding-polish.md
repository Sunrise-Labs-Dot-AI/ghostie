# Adversarial review — PR #3 (onboarding polish)

- **PR:** https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/3
- **Diff reviewed:** `5643c61..HEAD` (default-all onboarding + remove WhatsApp linking-risk screen)
- **Reviewer lane:** Codex (alternative model to the Claude authoring lane), review-only
- **Local verification at review time:** `swift build` clean, `swift test` green; CI required checks green.

## Findings & dispositions

### 1. Full user with all stored tools flag-hidden defaults to all-visible — Codex: BLOCKING → **downgraded to non-blocking, tests added**

`OnboardingView.initialChosenTools` / `normalizedChosenTools`: a returning `.full` user whose entire stored selection is currently feature-flag-hidden gets the full *visible* set pre-checked (previously: the recommended-3 subset, which also included Messages).

- **Disposition:** Not a new blocking regression. The pre-change code already defaulted this empty-after-filter case to a non-empty preset (recommended-3) that likewise included Messages; the change only widens that default to "all visible," which is the intended default-all model. Nothing is committed without the user reviewing the picker screen, and the precondition (returning full user whose whole selection is flag-hidden) is rare.
- **Action:** Behavior kept; pinned with `test_onboardingInitialChosenTools_fullUserWithStoredToolsAllFlagHidden_selectsVisibleSet` and `test_onboardingNormalizedChosenTools_emptyAfterFilterFallsBackToVisibleSet` so the intent is documented and the `normalizedChosenTools` fallback is covered.

### 2. WhatsApp opt-in copy no longer surfaces the Baileys risk — Codex: non-blocking → **rejected (maintainer decision)**

The moment-of-choice UI no longer states the unofficial-client ban risk; it lives only in the Terms of Service.

- **Disposition:** Intentional. The maintainer explicitly chose "remove the disclosure from the UI entirely; the Terms of Service (which onboarding requires accepting) is its home" over keeping an inline note. No change.

### 3. `acknowledgeWhatsAppRisk()` is a production-dead setter — Codex: nit → **already documented**

- **Disposition:** The setter already carries the comment *"Legacy writer kept so older UI/test paths can round-trip the persisted setting. New pairing flows do not call this."* That is the clarification requested; no change needed. The field is retained for settings-file compatibility.

## Structural checks (reviewer-confirmed)

- No dangling references to removed `recommendedToolIDs` or `.riskAcknowledgment` in `menubar/Sources` or `menubar/Tests`.
- SwiftUI `Phase` switches remain exhaustive after the enum-case removal.
