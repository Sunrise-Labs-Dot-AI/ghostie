# Texting Personalization Product Note

This note converts `texting-personalization-calibration.md` into product rules
for Texting Wrapped and future messaging-personality features.

## Supported Archetype Signals

These are safe to use as primary archetype evidence because they describe
observable behavior without claiming personality diagnosis:

- Message volume and active-thread breadth.
- Contact concentration, such as one very dominant top contact.
- Group-chat contribution share and active/silent group count.
- Inline emoji rate.
- Tapback/reaction rate, treated as its own style rather than as lurking.
- Reply latency for style labels only, not age.

## Playful Supporting Signals

These can add color, but should not carry a serious inference by themselves:

- Ball-in-court and left-on-read status.
- Talk/listen balance.
- Group-chat silence.

When these drive an archetype, mark the result as `support_level: "playful"` or
`support_level: "cautious"` and keep the wording light.

## Avoid For Texting Age

Do not use these to move the texting-age estimate:

- Reply latency.
- Slang-token counts.
- Tapbacks or reactions.
- Ball-in-court / left-on-read status.

The texting-age card should remain a guarded, playful single-number estimate and
should only render when the corpus has enough outbound messages, enough active
days, and at least three concrete writing-style drivers.

## Calibration Gaps

Public research is directional, not percentile-grade. First-party local
aggregate calibration is still needed for:

- Inline emoji-rate thresholds.
- Reaction/tapback-rate thresholds.
- Private group contribution distributions.
- Contact concentration and active-thread breadth.
- Daily volume buckets for modern iMessage and WhatsApp use.
