# Messages for AI — Design System ("Operator")

**Status:** authoritative, implementation-ready. This document is the single source of truth for restyling the macOS SwiftUI menu-bar app to the approved **"Operator"** direction.

**Two reference sources, and which wins on conflict:**

1. **Prototype (pixel reference):** `design/concepts/direction-operator.html` — a self-contained HTML/CSS prototype with the full token system under `[data-theme="light"]` (default) and `[data-theme="dark"]`, plus every component. Toggle Light/Dark in the header band to compare. When prose here and the prototype's pixels diverge, **the token tables in this doc win** (they were extracted from the prototype and corrected for SwiftUI); for spacing/geometry not fully specified in prose, **match the prototype**.
2. **Existing app (implementation target):** `menubar/Sources/MessagesForAIMenu/Views/`. This is a **restyle of a working app**, not a greenfield build. Every component below names the real Swift file/struct Codex edits.

This is a **restyle only**. No new features, no new screens, no behavior changes beyond what styling requires.

---

## 1. Overview & Principles

**The direction: "Operator" — a precise pro instrument, not a dashboard.** Flat matte surfaces. The content (threads and messages) is the protagonist; the chrome recedes.

**The five locked decisions (do not relitigate):**

1. **Hairlines are the only elevation.** 1px borders separate surfaces. No glows, no gradients on chrome, no spotlight blooms, no decorative cards. The window gets a single barely-there matte drop shadow; nothing else floats.
2. **One rationed accent.** iMessage blue `#0a7cff` is the *only* chromatic accent, and it appears in exactly two places: the **active sidebar nav item** (2px rail + blue glyph) and the **approval / hold-to-send gate** (the staged bubble, hold rail, hold readout). Status colors (green/amber/red) are functional signals, not accents — used only where they carry meaning.
3. **Native typography, sans/mono split.** SF Pro (system) for all display + UI + body. SF Mono for **every value the user reads**: timestamps, counts, status values, the API key, version strings, the hold readout. The sans↔mono contrast is the signature.
4. **Light is the default; Dark is a full first-class theme.** Both token sets are complete and specified below.
5. **Native message bubbles.** The transcript renders authentic iMessage (gray incoming, blue outgoing with tail) and WhatsApp (white/dark incoming, green outgoing with tail + ticks) bubbles, so each thread reads as the real service. Instrument signaling (the mono "AI DRAFT" tag, the hold rail) sits **around** the bubble and never changes its native shape, color, or radius.

**The thesis: instrument + native bubbles.** The app frame is a cold, quiet graphite/near-white instrument. Inside it, the conversation is rendered in its real service's skin. The approval gate is the one hot spot. That contrast — neutral instrument, authentic service bubbles, a single blue gate — is the product's visual identity and a deliberate advantage over a generic chat UI.

### Anti-patterns (reject on sight)

| Anti-pattern | Do instead |
|---|---|
| Glows, neon, drop-shadows on cards/rows/buttons | Hairline border only (`.hairline()`); elevation = border + the one window shadow |
| Gradients on chrome/surfaces | Flat matte fills from the surface ladder. (The ONLY gradients allowed are inside the native iMessage bubble fill, which is authentic Apple.) |
| Spotlight/decorative "hero cards" | Plain bordered containers (`set-card`, `status-card`) |
| Spraying the accent (blue buttons, blue toggles everywhere) | Accent ONLY on active nav + the approval gate. Everything else is neutral graphite. |
| Mono for labels/prose, or sans for values | Sans for labels/body; **mono for every value/metadatum** |
| System default tinted toggles when "on" | Neutral graphite "on" state (`toggle.on.neutral`); blue ON is reserved for the approval gate only |
| Colored/filled section backgrounds | White/graphite cards, mono uppercase group label, trailing hairline rule |

---

## 2. Design Tokens

These are exact, extracted from the prototype's CSS custom properties. Define them once in a `DesignSystem/` layer (see §6). Every token has a Light value and a Dark value.

### 2.1 Color — LIGHT (default)

| Token | Value | Role |
|---|---|---|
| **Surfaces** | | |
| `g000` desktop backdrop | `#EEF1F5` | window-behind / outermost (rarely visible in-app) |
| `g050` window base | `#FFFFFF` | window background, titlebar-adjacent |
| `g080` sidebar | `#F6F8FA` | sidebar fill, time-box/field fills, status-pill fill |
| `g100` content | `#FFFFFF` | main content pane |
| `g130` raised / card | `#FAFBFC` | cards (settings, status, home-foot), thread-row hover, avatar-adjacent |
| `g160` hover / selected | `#F1F4F8` | nav active fill, thread-row selected fill |
| `g200` control fill | `#F3F5F8` | button fill, toggle track (off), avatar fill |
| `g260` control hover | `#E9EDF2` | button hover fill |
| **Hairlines** | | |
| `line` | `#E4E8EE` | default 1px border (cards, dividers, sidebar edge) |
| `line2` | `#DFE4EB` | window border, control borders (slightly stronger) |
| `lineStrong` | `#CDD4DD` | emphasized hairline (caption tick, avatar/glyph border) |
| `lineFaint` | `#EEF1F5` | inner row separators inside a card |
| **Ink** | | |
| `ink` primary | `#111317` | primary text, titles |
| `ink2` secondary | `#3F4751` | secondary text, nav labels, button text |
| `ink3` muted / meta | `#6A727D` | muted captions, mono meta values (slate) |
| `ink4` faint | `#99A1AC` | faintest labels, group labels, timestamps |
| **Accent (rationed)** | | |
| `blue` | `#0A7CFF` | the one accent: active nav, approval gate |
| `blueEdge` | `#0A6AE0` | 2px leading edge of the hold fill (darker on light) |
| `blueDim` | `rgba(10,124,255,0.16)` | blue chip border, dim accent fill |
| `blueRail` | `rgba(10,124,255,0.45)` | hold-rail accents |
| **Status** | | |
| `green` | `#0F9D6B` | running/connected/sent |
| `greenDim` | `rgba(15,157,107,0.18)` | green chip/border/check |
| `amber` | `#B9791B` | scheduled/pending |
| `amberDim` | `rgba(185,121,27,0.22)` | amber chip/border |
| `red` | `#FF5F57` | error / attention dot / traffic-light |
| **Native bubbles** | | |
| `imsgInBg` | `#E9E9EB` | iMessage incoming (gray) |
| `imsgInText` | `#000000` | iMessage incoming text |
| `imsgBlue1` | `#1FA2FF` | iMessage outgoing gradient TOP (theme-independent) |
| `imsgBlue2` | `#0A7CFF` | iMessage outgoing gradient BOTTOM (theme-independent) |
| `imsgOutText` | `#FFFFFF` | iMessage outgoing text |
| `waInBg` | `#FFFFFF` | WhatsApp incoming |
| `waInText` | `#111B21` | WhatsApp incoming text |
| `waOutBg` | `#D9FDD3` | WhatsApp outgoing |
| `waOutText` | `#111B21` | WhatsApp outgoing text |
| `waTick` | `#34B7F1` | WhatsApp read-receipt ticks |

### 2.2 Color — DARK

| Token | Value | Role |
|---|---|---|
| **Surfaces** | | |
| `g000` desktop backdrop | `#0C0D0F` | window-behind / outermost |
| `g050` window base | `#111316` | window background |
| `g080` sidebar | `#14161A` | sidebar fill, field/time-box fills, status-pill fill |
| `g100` content | `#16191D` | main content pane |
| `g130` raised / card | `#1A1D22` | cards, row hover |
| `g160` hover / selected | `#1E2127` | nav active fill, thread-row selected fill |
| `g200` control fill | `#23272E` | button fill, toggle track (off), avatar fill |
| `g260` control hover | `#2B2F37` | button hover fill |
| **Hairlines** | | |
| `line` | `rgba(255,255,255,0.07)` | default 1px border |
| `line2` | `rgba(255,255,255,0.10)` | window/control borders |
| `lineStrong` | `rgba(255,255,255,0.14)` | emphasized hairline |
| `lineFaint` | `rgba(255,255,255,0.045)` | inner row separators |
| **Ink** | | |
| `ink` primary | `#ECEEF1` | primary text |
| `ink2` secondary | `#B6BCC6` | secondary text, nav labels |
| `ink3` muted / meta | `#7E858F` | muted captions, mono meta |
| `ink4` faint | `#5A606A` | faintest labels, timestamps |
| **Accent (rationed)** | | |
| `blue` | `#0A7CFF` | the one accent |
| `blueEdge` | `#3A96FF` | hold leading edge (brighter on dark) |
| `blueDim` | `rgba(10,124,255,0.16)` | blue chip border |
| `blueRail` | `rgba(10,124,255,0.40)` | hold-rail accents |
| **Status** | | |
| `green` | `#11B981` | running/connected/sent |
| `greenDim` | `rgba(17,185,129,0.16)` | green chip/border/check |
| `amber` | `#E0A23A` | scheduled/pending |
| `amberDim` | `rgba(224,162,58,0.16)` | amber chip/border |
| `red` | `#FF5F57` | error / attention / traffic-light |
| **Native bubbles** | | |
| `imsgInBg` | `#3B3B3D` | iMessage incoming (dark gray) |
| `imsgInText` | `#FFFFFF` | iMessage incoming text |
| `imsgBlue1` | `#1FA2FF` | iMessage outgoing gradient TOP (same both themes) |
| `imsgBlue2` | `#0A7CFF` | iMessage outgoing gradient BOTTOM (same both themes) |
| `imsgOutText` | `#FFFFFF` | iMessage outgoing text |
| `waInBg` | `#202C33` | WhatsApp incoming (dark) |
| `waInText` | `#E9EDEF` | WhatsApp incoming text |
| `waOutBg` | `#005C4B` | WhatsApp outgoing (dark green) |
| `waOutText` | `#E9EDEF` | WhatsApp outgoing text |
| `waTick` | `#53BDEB` | WhatsApp ticks |

> **Theme-independent:** `imsgBlue1/2` are identical in both themes (authentic Apple). The *incoming* bubble surfaces (`imsgInBg`, `waInBg`) switch per theme because they mirror the OS. WhatsApp outgoing also switches (light pale-green vs dark green).

### 2.3 Color — SwiftUI mapping

**Recommended mechanism: a `colorScheme`-keyed `DS.Color` namespace** (not an asset catalog) — it keeps every value in one auditable Swift file, makes the Light/Dark pairing explicit, and avoids a wall of `.xcassets` JSON in a SwiftPM target. Read the environment `colorScheme` once at the top of the shell and thread a `Theme` (or use `@Environment(\.colorScheme)` inside a small resolver).

Pattern (illustrative — Codex implements):

```swift
enum DS {
  enum Color {
    // Each token is a function of the scheme.
    static func g050(_ s: ColorScheme) -> SwiftUI.Color { s == .dark ? hex(0x111316) : .white }
    static func sidebar(_ s: ColorScheme) -> SwiftUI.Color { s == .dark ? hex(0x14161A) : hex(0xF6F8FA) }
    static func line(_ s: ColorScheme) -> SwiftUI.Color {
      s == .dark ? SwiftUI.Color.white.opacity(0.07) : hex(0xE4E8EE)
    }
    static func ink(_ s: ColorScheme) -> SwiftUI.Color { s == .dark ? hex(0xECEEF1) : hex(0x111317) }
    static let blue = hex(0x0A7CFF)            // accent is theme-independent
    // iMessage outgoing gradient (theme-independent):
    static let imsgBlueTop = hex(0x1FA2FF)
    static let imsgBlueBottom = hex(0x0A7CFF)
    // …one accessor per token in §2.1/§2.2…
  }
}
private func hex(_ v: UInt) -> SwiftUI.Color {
  SwiftUI.Color(.sRGB,
    red: Double((v >> 16) & 0xFF)/255, green: Double((v >> 8) & 0xFF)/255,
    blue: Double(v & 0xFF)/255, opacity: 1)
}
```

If Codex prefers asset catalogs instead, that's acceptable: create one Color Set per token with **Any Appearance = Light value, Dark Appearance = Dark value**, name them `ds/g050`, `ds/line`, `ds/ink`, etc., and expose them through the same `DS.Color` names. Either way the call sites read `DS.Color.x`. Do **not** reach for `Color.accentColor` or `NSColor` semantic colors for surfaces/ink — those bypass the token system. (Exception: the iMessage outgoing bubble intentionally uses the literal Apple gradient, not the system accent.)

### 2.4 Typography

Native only: SF Pro via `Font.system(...)` and SF Mono via `design: .monospaced`. No bundled webfonts. SF Pro Display↔Text optical sizing is automatic in `.system`. Mono roles must use `.monospacedDigit()` / tabular figures so values don't jitter.

| Role | Size (pt) | Weight | Tracking | Family | Case | SwiftUI |
|---|---|---|---|---|---|---|
| Page title (Home) | 26 | bold (`.bold`) | tight (-0.02em ≈ default tight) | SF Pro | — | `.system(size: 26, weight: .bold)` |
| Pane title (Messages/Health/Scheduled) | 22–24 | bold | tight | SF Pro | — | `.system(size: 24, weight: .bold)` |
| Thread-list title ("Messages" col head) | 21 | semibold | tight | SF Pro | — | `.system(size: 21, weight: .semibold)` |
| Settings title | 20 | semibold | tight | SF Pro | — | `.system(size: 20, weight: .semibold)` |
| Section / group label | 9.5–10 | semibold | **+0.20–0.22em** | **SF Mono** | UPPERCASE | `.system(size: 10, weight: .semibold, design: .monospaced)` + `.tracking(2)` + `.textCase(.uppercase)` |
| Row title / contact name | 13 | semibold (550 ≈ `.semibold`) | — | SF Pro | — | `.system(size: 13, weight: .semibold)` |
| Detail header name | 14 | semibold | — | SF Pro | — | `.system(size: 14, weight: .semibold)` |
| Message body (bubble) | 13.5 | regular | — | SF Pro | — | `.system(size: 13.5)` (line-height ~1.32) |
| Settings row label | 13 | medium | — | SF Pro | — | `.system(size: 13, weight: .medium)` |
| Settings helper caption | 11 | regular | — | SF Pro | — | `.system(size: 11)` + `ink3` |
| Caption / meta (sans) | 11.5 | regular | — | SF Pro | — | `.system(size: 11.5)` |
| **Mono value** (handle, status value, sched time, build) | 10.5–11.5 | regular | +0.02–0.04em | **SF Mono** | — | `.system(size: 11, design: .monospaced).monospacedDigit()` |
| Mono micro-value (timestamp, hold readout) | 9.5–10 | regular/semibold | +0.04em | **SF Mono** | — | `.system(size: 10, design: .monospaced)` |
| Count chip / badge | 10 | semibold/bold | — | **SF Mono** | — | `.system(size: 10, weight: .semibold, design: .monospaced)` |
| Status pill text | 10 | semibold | +0.06em | **SF Mono** | UPPERCASE | `.system(size: 10, weight: .semibold, design: .monospaced)` + `.tracking(0.6)` |
| Approval tag ("AI DRAFT…") | 9 | regular | **+0.14em** | **SF Mono** | UPPERCASE | `.system(size: 9, design: .monospaced)` + `.tracking(1.3)` |
| Button label | 11.5 | medium | — | SF Pro | — | `.system(size: 11.5, weight: .medium)` |
| Sidebar nav label | 12.5 | regular (450) | — | SF Pro | — | `.system(size: 12.5)` |
| Sidebar wordmark | 12.5 | semibold | — | SF Pro | — | `.system(size: 12.5, weight: .semibold)` |
| Titlebar mono name | 11 | regular | +0.03em | **SF Mono** | — | `.system(size: 11, design: .monospaced)` + `ink4` |
| Sidebar foot ("v0.5.1 · …") | 9.5 | regular | — | **SF Mono** | — | `.system(size: 9.5, design: .monospaced)` + `ink4` |

`DS.Font` extension (illustrative):

```swift
extension DS { enum Font {
  static let pageTitle   = SwiftUI.Font.system(size: 26, weight: .bold)
  static let paneTitle   = SwiftUI.Font.system(size: 24, weight: .bold)
  static let rowTitle    = SwiftUI.Font.system(size: 13, weight: .semibold)
  static let bubbleBody  = SwiftUI.Font.system(size: 13.5)
  static let groupLabel  = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
  static let monoValue   = SwiftUI.Font.system(size: 11, design: .monospaced)
  static let monoMicro   = SwiftUI.Font.system(size: 10, design: .monospaced)
  static let chip        = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
  static let pill        = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
  static let approvalTag = SwiftUI.Font.system(size: 9, design: .monospaced)
} }
```

Apply `.tracking(_:)` and `.textCase(.uppercase)` at the call site for the uppercase mono roles. The **rule Codex must internalize:** if a glyph is a *value the user reads* (number, timestamp, status word, handle, key, version), it is mono. If it's a *label or prose*, it is sans.

### 2.5 Spacing — 4px grid

All padding/margins/gaps are multiples of 4. Scale and usage:

| Token | px | Usage |
|---|---|---|
| `xs` | 4 | chip internal gap, micro-row gaps, nav active rail inset |
| `s` | 8 | nav row gap, thread chips gap, bubble→meta gap, icon-button internal |
| `m` | 12 | card row vertical padding base, detail-head gap, bubble cluster gap |
| `l` | 16 | card row horizontal padding, settings nested margin, diag rows |
| `xl` | 20 | thread-list head padding, band padding |
| `2xl` | 24 | pane horizontal padding (DraftsPane header), home/scheduled outer |
| `3xl` | 28 | group spacing in settings, home/scheduled outer padding |
| `4xl` | 36 | settings-inner side padding, band bottom margin |

When a spacing isn't listed for a specific component, **read it off the prototype CSS and round to the nearest 4** (the component tables below cite the prototype's exact px).

### 2.6 Radii

| Element | Radius | SwiftUI shape |
|---|---|---|
| Card (`set-card`, `status-card`, `home-foot`, window) | **12** | `RoundedRectangle(cornerRadius: 12, style: .continuous)` |
| Control (button, toggle-not-pill, field, time-box, select) | **6** | `RoundedRectangle(cornerRadius: 6, style: .continuous)` |
| Badge / chip / approval-tag / status-badge | **2** | `RoundedRectangle(cornerRadius: 2, style: .continuous)` |
| Native message bubble | **18** | `RoundedRectangle(cornerRadius: 18, style: .continuous)`; **tail corner = 6** (bottom-left for incoming, bottom-right for outgoing) |
| Avatar monogram | 8 | `RoundedRectangle(cornerRadius: 8)` |
| Thread-list row container | 8 | `RoundedRectangle(cornerRadius: 8)` |
| Pill (status-pill, theme-seg, toggle track, hold-track, nav-badge) | ∞ | `Capsule()` |

> The bubble "tail corner = 6" means the corner nearest the tail is squared to 6pt while the other three stay 18pt — exactly how Messages.app draws it. Implement with a custom shape or asymmetric corner radii; the actual tail wedge is a small clipped shape (see §4 bubbles). The existing app currently uses a uniform `cornerRadius: 16` with no tail (`ConfirmedMessageBubble`, `ContextBubbleView`, `holdableBubble`) — the restyle moves to 18 + tail.

### 2.7 Hairlines & Elevation

**Elevation = a 1px hairline + (for the window only) one matte shadow. Never a glow.**

1px border per theme uses `line`/`line2`/`lineStrong`/`lineFaint` from §2.1–2.2. On a 2× Retina display, a 1pt SwiftUI stroke renders as a crisp hairline; keep stroke width `1` (use `0.5`–`1` only where the prototype uses `line-faint` inner separators and you want them lighter).

**Window shadow (the only shadow in the app):**

- **Light:** `0 0 0 1px rgba(16,20,28,0.02)`, `0 14px 40px rgba(16,20,28,0.10)`, `0 2px 6px rgba(16,20,28,0.06)`
- **Dark:** `0 18px 50px rgba(0,0,0,0.55)`, `0 2px 8px rgba(0,0,0,0.40)`, plus a `0 1px 0 rgba(255,255,255,0.04)` inset top-light

In a real macOS `Window`/`NavigationSplitView` the OS draws the window shadow; you generally do **not** re-create it inside SwiftUI. Treat the prototype's window shadow as the look the native window already provides — do not add `.shadow()` to in-window content. The one sanctioned in-app soft shadow is the existing toast/hover-button micro-shadow, which the restyle should keep minimal (radius ≤ 5).

ViewModifier patterns (illustrative):

```swift
extension View {
  func hairline(_ scheme: ColorScheme, _ color: ((ColorScheme) -> Color) = DS.Color.line,
                radius: CGFloat = 12, width: CGFloat = 1) -> some View {
    overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(color(scheme), lineWidth: width))
  }
  /// A card: matte fill + hairline. No shadow (elevation is the border).
  func dsCard(_ scheme: ColorScheme, radius: CGFloat = 12) -> some View {
    background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.Color.g130(scheme)))
      .hairline(scheme, DS.Color.line, radius: radius)
  }
}
```

`.elevation()` exists only as "apply `.dsCard`"; there is deliberately no glow/large-shadow modifier.

### 2.8 Motion

| Motion | Timing | Notes |
|---|---|---|
| Theme cross-fade | **0.18s ease** on `background-color`/`border-color`/`color` | The prototype transitions surfaces on theme flip. In SwiftUI, wrap the colorScheme-driven re-render in `.animation(.easeInOut(duration: 0.18), value: colorScheme)` on the shell, or accept the OS default fade. |
| Hold-to-send fill | **1.0s linear** default; **2.0s linear** when `induced_by_unknown_contact` | Already implemented: `withAnimation(.linear(duration: holdDuration))` in `PendingMessageBubble.beginHold()`. Keep the linear curve so the fill maps 1:1 to elapsed time and the mono readout stays truthful. |
| Hold cancel | 0.12s ease-out back to 0 | Already implemented (`cancelHold()`). |
| Hover (nav, rows, action chips) | 0.14s ease-in-out | Matches existing `onHover` animations; keep subtle. |
| Bubble insert/remove (sent transition) | spring(response 0.32, damping 0.86) | Existing `DraftThreadDetail` animation — keep. |
| **Reduced motion** | Respect `@Environment(\.accessibilityReduceMotion)`. When true: drop the theme cross-fade and hover scale; **keep** the hold fill (it is the gesture's only feedback) but you may render it as discrete steps rather than a continuous animation. |

---

## 3. Layout & Information Architecture

**Shell:** a `NavigationSplitView` — fixed-width sidebar + content pane. Window chrome is the standard macOS titlebar (traffic lights + centered mono title). Rendered by **`ConsoleView.swift`** (the split view, sidebar `List`, and `detail` switch).

**Sidebar:** width **220pt** (prototype `.sidebar { width: 220px }`). Existing app uses `navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)` — keep ideal 220. Fill = `sidebar` (`g080`). Right edge = 1px `line`.

**Nav structure (top group, then a `LABS` group):**

| Item | Badge / indicator | Renders (detail) |
|---|---|---|
| Home | — | `HomePane` |
| Messages | count badge (active draft count) | `DraftsPane` |
| Automations | count badge (amber if pending approvals) | `AutomationsView` |
| Scheduled | — | `ScheduledPane` |
| Health | — | `HealthPane` |
| Settings | **attention dot** (red) when daemon needs attention | `SettingsView` |
| **— LABS group header —** | | |
| Texting Style | — | `TextingVoiceView` |
| Don't Ghost | — | `DontGhostView` |
| EQ | — | `EQView` |
| Texting Analytics | — | `TextingAnalyticsView` |
| Texting Wrapped | — | `WrappedToolView` |
| Birthday Texts | — | `BirthdayToolView` |

> **IA note / current-state gap:** the prototype sidebar shows Home, Messages, Automations, Scheduled, Health, Settings in the top group. The current `ConsoleView` top `Section` only lists **Messages, Automations, Settings**, and routes `.home/.scheduled/.health` to fallback views. The Labs group already matches (`ToolRegistry.all`). **Restyle scope:** style what exists; **adding the missing Home/Scheduled/Health nav rows is an IA change** — see §7 open questions. Default recommendation: add the three rows so the sidebar matches the prototype, since the panes (`HomePane`, `ScheduledPane`, `HealthPane`) already exist and are merely unrouted.

**Sidebar wordmark** (top): 20×20 bordered glyph (1px `lineStrong`, radius 5) + "Messages for AI" at 12.5pt semibold. **Sidebar foot** (bottom, above window edge): a 5px green `live` dot + mono `v0.5.1 · 2 engines live`, on a `lineFaint` top border.

**Screen inventory:**

| Screen | Swift view | Notes |
|---|---|---|
| Messages / approval (hero) | `DraftsPane` (+ `DraftThreadDetail`, `PendingMessageBubble`, `ContextBubbleView`, `ConfirmedMessageBubble`) | three-column: thread list (348pt) + detail |
| Settings | `SettingsView` | nested groups (the called-out win) |
| Scheduled | `ScheduledPane` | amber-tagged queue |
| Health | `HealthPane` | diagnostics checklist |
| Home | `HomePane` | status card + Labs hint |
| Automations | `AutomationsView` | (restyle to tokens; not separately specced here) |
| Labs (6 tools) | `TextingVoiceView`, `DontGhostView`, `EQView`, `TextingAnalyticsView`, `WrappedToolView`, `BirthdayToolView` | apply tokens/typography; out of detailed scope but must not look out-of-system |

---

## 4. Components

Each component lists anatomy, key measurements (cite prototype), states, and the Swift file/struct to edit.

### 4.1 Sidebar & nav row — `ConsoleView.swift` (sidebar `List`)

**Anatomy:** icon (15×15, `ink3`) + label (12.5pt sans, `ink2`) + trailing badge/dot.
**Measurements:** row padding `7px 8px`, gap `10px`, radius 6, group gap `1px`.

| State | Spec |
|---|---|
| Default | label `ink2`, icon `ink3`, no fill |
| Hover | fill `g130` |
| **Active** | fill `g160`, label `ink`, **icon `blue`**, and a **2px blue rail** on the leading edge (inset 4px top/bottom, radius `0 2 2 0`). This is one of only two accent uses. |
| With count badge | trailing `nav-badge`: mono 10pt semibold, min-width 18, height 16, Capsule, fill `g200`, border `line`, text `ink2` |
| Attention dot | 6×6 red `Capsule`/Circle, trailing, `margin-left:auto` |

> SwiftUI note: the default `.listStyle(.sidebar)` selection highlight is a system capsule. To get the Operator active state (fill + 2px leading rail + blue glyph), the row content must render its own background + leading rail and you should suppress/override the system selection tint. Build each row as a custom `Label`-like view that reads whether it is the selected `tag` and applies the active treatment. Keep `List(selection:)` for keyboard nav.

**LABS group header:** mono 9.5pt, `+0.2em` tracking, UPPERCASE, `ink4`, padding `0 8 8`. Preceded by a `side-divider` (1px `line`, margins `14 4 12`). In SwiftUI this is `Section("LABS")` restyled — the default `Section` header is close; restyle its text to the mono group-label spec.

### 4.2 Window chrome / titlebar

Standard macOS: traffic lights left (12×12: red `#FF5F57`, yellow `#FEBC2E`, green `#28C840` — these are OS-drawn, not yours), **centered mono title** `messages-for-ai` at 11pt mono, `ink4`. Titlebar fill = `g080`, bottom border 1px `line`, height 38.

> The native window already draws traffic lights and a titlebar. To get the centered mono title, set the SwiftUI `.navigationTitle` and rely on the OS titlebar, OR (to match the prototype's centered mono look exactly) hide the system title and render your own centered mono `Text` in a toolbar `.principal` item. Recommended: native titlebar + a `.toolbar { ToolbarItem(placement: .principal) { Text("messages-for-ai").font(DS.Font.monoValue)… } }`.

### 4.3 Thread-list row — `DraftsPane.swift` › `DraftThreadRow`

**Anatomy:** monogram avatar (34×34) + name (sans 13pt semibold) over handle/subtitle (mono 10.5pt `ink3`) + trailing chips + optional platform badge.
**Measurements (prototype `.convo`):** row padding 10, gap 11, radius 8, avatar 34×34 radius 8 with 1px `line2` border and `g200` fill, monogram mono 11pt semibold `ink2`. WhatsApp avatar variant: border `greenDim`, text `green`. Thread-list column width **348pt** (prototype `.threadlist { width:348px }`); existing app uses `minWidth:240, ideal:280, max:340` — widen ideal toward 300–348.

| State | Spec |
|---|---|
| Default | transparent fill, 1px transparent border |
| Hover | fill `g130` |
| Selected | fill `g160`, border `line`, **2px blue leading rail** (top/bottom inset 9, radius `0 2 2 0`) |

> Current `DraftThreadRow` shows **only name + chips** (no avatar, no handle subtitle). The restyle adds: the monogram avatar (derive 2-letter monogram from `displayName`), the mono handle/subtitle line, and the selected-state rail. Keep `CountChip` logic (draft/scheduled/sent) but restyle to §4.4.

### 4.4 Count chip / badge — `DraftsPane.swift` › `CountChip`; `PlatformBadge` in `PlatformStyling.swift`

**Anatomy:** icon (10×10) + mono count. Height 18, padding `0 6`, radius 2, border 1px, fill `g130`, mono 10pt semibold.

| Variant | Color | Meaning |
|---|---|---|
| Draft | `blue` text, `blueDim` border | pending plain drafts (pencil icon) |
| Scheduled | `amber` text, `amberDim` border | scheduled (clock icon) |
| Sent | `green` text, `greenDim` border | confirmed (checkmark icon) |

> Current `CountChip` is a tinted `Capsule` with `tint.opacity(0.14)` fill. Restyle to: **radius-2 rectangle**, mono font, `g130` fill, 1px colored border (not a filled capsule). The draft chip's tint must become `blue` (`DS.Color.blue`), not `Platform.accentColor` — though for iMessage these coincide, this matters so the chip is the rationed blue, not a system-accent that the user may have themed.
> `PlatformBadge` (the "WhatsApp" tag): restyle to mono 8.5pt, UPPERCASE, `green` text, `greenDim` 1px border, radius 2, transparent/`g130` fill — matching prototype `.wa-badge`. Shown only for non-iMessage threads (keep existing guard).

### 4.5 Message bubbles — `ContextBubbleView.swift`, `ConfirmedMessageBubble` (in `DraftsPane.swift`)

Authentic per-service bubbles. **Geometry (both):** padding `7px 13px 8px`, body 13.5pt sans, line-height ~1.32, radius **18** with the tail corner squared to **6**, max-width ~70% of transcript. Tail is a small wedge at the bottom corner (incoming bottom-left, outgoing bottom-right), ~16×18, filled with the bubble's color.

| Bubble | Fill | Text | Tail | Per-theme |
|---|---|---|---|---|
| iMessage incoming | `imsgInBg` | `imsgInText` | bottom-left, gray | yes (`#E9E9EB`/`#3B3B3D`) |
| iMessage outgoing | **linear gradient top→bottom `imsgBlue1`→`imsgBlue2`** | white | bottom-right, solid `imsgBlue2` | no (same both themes) |
| WhatsApp incoming | `waInBg` | `waInText` | bottom-left; **add 1px `line` border** (prototype gives wa-in a hairline) | yes |
| WhatsApp outgoing | `waOutBg` | `waOutText` | bottom-right | yes (pale green / dark green) |

**Timestamp:** OUTSIDE the bubble, below it. Mono 9.5pt `ink4`. Outgoing: margin `4 8 0 0` (right-aligned). Incoming: margin `4 0 0 8` (left-aligned). Existing `ContextBubbleView` already puts the timestamp below; switch its font to mono and color to `ink4`.

**WhatsApp ticks:** outgoing WhatsApp shows a double-check glyph tinted `waTick`, inline at the end of the meta line (see prototype `.mini.wa-out .meta svg`). Render as a small SF Symbol (`checkmark` doubled) or a custom glyph, ~11×8, colored `waTick`.

> Current state: `ContextBubbleView` uses uniform radius 14, `Platform.accentColor` fill for from-me, `.quaternaryLabelColor` for incoming, no tail, no gradient, no ticks. `ConfirmedMessageBubble` uses radius 16, flat `accentColor` fill. **Restyle both to the native-bubble spec above** (18 + tail, gradient for iMessage out, `waOut`/`imsgIn` tokens, mono timestamps, WhatsApp ticks). This is what makes the transcript read as the real service — do not approximate with a flat accent rectangle.

### 4.6 Approval object (HERO) — `DraftsPane.swift` › `PendingMessageBubble`

The single most important surface. A **genuine iMessage-blue outgoing bubble** in a *staged* (pre-send) state, with Operator instrument signaling around it.

**Anatomy (top to bottom, right-aligned, max-width ~74% of transcript):**

1. **Mono tag** above the bubble: `[pulse dot] AI DRAFT · HOLD TO SEND · iMessage`. Tag = mono 9pt, `+0.14em` tracking, UPPERCASE, `ink3`; fill `g130`, 1px `line` border, radius 2, padding `3 8`, margin-bottom 7. The `· iMessage` source suffix is `ink4`. The 5px pulse dot is `blue` (gently breathing opacity is optional polish).
2. **Bubble row:** edit/delete icon-buttons to the LEFT of the bubble (so they never overflow the right edge), then the bubble.
   - **Icon buttons** (`.approval-actions` / current `HoverActionButton`): 22×22, radius 5, 1px `line2` border, `g130` fill, icon 12×12 `ink3`; hover → `ink` + `g200`. Stacked vertically. Visible on hover or while editing.
   - **Bubble** (`.approval-bubble`): real iMessage blue gradient (`imsgBlue1`→`imsgBlue2`), white text, radius 18, tail-corner 6, tail bottom-right solid `imsgBlue2`. Inset top sheen `inset 0 1px 0 rgba(255,255,255,0.22)`. **Staged is signaled by the tag + hold rail, NOT by transparency** — the bubble is solid authentic blue.
3. **Hold rail (satellite, beneath the bubble), width ~248pt, right-aligned:**
   - **Readout row:** left = `[→ glyph] HOLD · 0.55s` (mono 10pt, `blue`); right = `55%` (mono 10pt semibold, the number `blue`, the `%` `ink2`).
   - **Track:** height 6, Capsule, fill `g080`, 1px `line` border. **Fill:** `blue`, width = progress%, with a crisp **2px leading edge** colored `blueEdge` (no blur/glow).
   - **Hint:** mono 9.5pt `ink3`, e.g. `Keep holding to send…`.

**States:**

| State | Treatment |
|---|---|
| Idle | tag + solid blue bubble; hold rail readout `HOLD · 0.00s` / `0%`, empty track; hint `Press & hold to send`. Actions hidden until hover. |
| Holding | fill animates 0→100% over the hold duration; readout counts up `HOLD · 0.42s` / `42%`; hint `Keep holding to send…`. |
| Sent | bubble transitions to a confirmed (flat) outgoing bubble (`ConfirmedMessageBubble`), green check + mono "Sent" meta; rail disappears. |

> **Mapping to current code:** `PendingMessageBubble` already implements the gesture, the progress fill (`progressBubbleBackground`), the hold duration switch, edit/delete `HoverActionButton`s, and a toast. The restyle changes the *visuals*: (a) bubble becomes the **iMessage-blue gradient with tail + 18 radius** instead of today's dashed-outline transparent rectangle (`bubbleOutline`/`progressBubbleBackground` with `reviewState` dashed stroke); (b) add the **mono "AI DRAFT · HOLD TO SEND · iMessage" tag** above; (c) replace the in-bubble progress wash with the **separate hold rail** (track + fill + 2px `blueEdge` leading edge + mono readout/percent) beneath the bubble; (d) the "Drafted 3m ago" / hold labels become mono. Keep all gesture/timing logic untouched.
> The current `PendingReviewState` renders staged drafts as a **dashed translucent outline** — the Operator hero replaces that with a **solid authentic-blue bubble + external hold rail**. Staged-ness is communicated by the tag and rail, per the locked decision.

### 4.7 Hold-to-send interaction spec — `PendingMessageBubble`

| Aspect | Spec | Current code |
|---|---|---|
| Gesture | press-and-hold on the bubble; `DragGesture(minimumDistance: 0)` | implemented |
| Duration (default) | **1.0s** | `holdDuration = 1.0` |
| Duration (induced) | **2.0s** when `draft.induced_by_unknown_contact == true` | implemented |
| Progress mapping | linear; `progress` 0→1 over duration; readout shows `HOLD · {elapsed}s` and `{round(progress*100)}%` | fill animation implemented; **readout text must be added** (mono) |
| Completion | at 100%, fire: scheduled-unapproved → approve; else → send | implemented (`fireTask`) |
| Cancel | release before 100% → fill eases back to 0 (0.12s) | implemented (`cancelHold`) |
| Scheduled variant | a queued scheduled draft shows **"Press & hold to send now"** as the hint; holding sends immediately (override) | `accessibilitySendLabel` / `holdingInlineLabel` cover this; surface the hint text in mono |
| Held-reason chips | mono amber chip: `quiet_hours → "Held · quiet hours"`, `stale → "Held · past date"`, `needs_approval → "Needs approval"`, `send_failed → "Held · send failed"` | `holdLabel()` implemented; restyle chip to mono + radius-2 amber |

The induced-contact warning (`InducedDraftBadge.swift`) sits above the approval object: restyle its container to a radius-6, `amberDim` fill + 1px amber border, amber `exclamationmark.triangle.fill`, sans title + sans caption. (It already approximates this — just move colors onto tokens.)

### 4.8 Scheduled bubble — `ScheduledPane.swift` rows; inline scheduled in `PendingMessageBubble`

Inline (in the transcript): the same real iMessage-blue bubble **at rest**, lightly dimmed (opacity ~0.72), tagged with a mono **amber `SCHEDULED · Jun 6, 12:02 PM`** satellite chip (`amber` text, `amberDim` 1px border + fill, radius 2, mono 9.5pt UPPERCASE, clock icon) and a mono hint `Press & hold to send now`.

`ScheduledPane` (the dedicated tab) rows: restyle each row card to `dsCard` (radius 12, `g130` fill, 1px `line`); name sans 15pt semibold; body sans `ink2`; the scheduled time → mono `ink3`; held-reason → mono amber radius-2 chip (§4.7). Buttons → §4.10.

### 4.9 Status pill / status dot — `SettingsView.swift` (`status-pill`), `HomePane.swift`, `HealthPane.swift`

**Status pill** (`RUNNING`/`CONNECTED`): height 22, padding `0 9`, Capsule, mono 10pt semibold UPPERCASE `+0.06em`, border 1px, fill `g080`, plus a 6px dot. Default text `ink2`; **ok variant**: text `green`, border `greenDim`, dot `green`. (Amber/red variants follow the same pattern with `amber`/`red` tokens.)

**Status dot** (Home/Health rows): 8px circle. `green` = ok, `amber` = pending, `red`/orange = bad. Existing `HomePane.Tone` (`.ok/.pending/.bad`) maps directly — point its `.color` at `DS.Color.green/amber/red`. `HealthPane` uses SF Symbols (`checkmark.circle.fill`/`clock.fill`/`exclamationmark.circle.fill`) — keep symbols but recolor to tokens; the value text (`Granted`, `Running`) becomes mono.

### 4.10 Controls — `SettingsView.swift` (`SwitchButton`, `btn`, time/select), `OnboardingView.swift`

| Control | Spec | Current |
|---|---|---|
| Toggle / switch | track 38×22 Capsule, 1px `line2`, fill `g200`; knob 16×16. **OFF** knob `ink2` left. **ON (neutral, default for all settings):** track `g260`, border `lineStrong`, knob `ink` right — **no accent**. **ON (gate only):** track + border `blue`, knob white. | `SwitchButton` is 36×22, ON = `Color.accentColor`. Restyle: 38×22, **neutral ON** (graphite, not accent) for every settings toggle; reserve blue ON for the approval gate exclusively. |
| Button (secondary/borderless) | height 26, padding `0 11`, radius 6, 1px `line2`, fill `g200`, sans 11.5pt medium `ink2`, icon 12×12; hover `g260` + `ink` | `.bordered`/`.borderless` system buttons → restyle to this token set |
| Primary button | reserve for genuinely primary actions; otherwise prefer the secondary style. If a filled primary is needed it uses `blue` fill — use sparingly (the gate is the real primary). | `.borderedProminent` currently blue — keep only where truly primary (e.g. Scheduled "Send now"), otherwise neutral |
| Segmented control | mono 10pt UPPERCASE, Capsule track, 2px inner padding, active segment = `g200` fill + 1px `line` inset; active glyph tinted `blue` (theme toggle only) | Compose/transport pickers use `.segmented` — restyle to mono segmented look |
| Time control | mono 11pt; `time-box` = 1px `line2`, radius 6, `g080` fill, padding `4 8`, text `ink`; separator `→` `ink4` | `SettingsView` time bindings — wrap values in mono `time-box` styling |
| Masked key field | row: lock icon 13×13 `ink4` + mono `sk-ant-•••••••••••••••3a9f`; container height 30, min-width 280, 1px `line2`, radius 6, `g080` fill, mono 12pt `ink` | API key row — render the masked value in mono |
| Icon button | 22×22, radius 5, 1px `line2`, `g130` fill, icon 12×12 `ink3`; hover `ink`+`g200` | approval actions (§4.6) |
| Select (mono) | height 26, padding `0 9`, radius 6, 1px `line2`, `g080` fill, mono 11pt `ink` + chevron 11×11 `ink4` | update-frequency picker |

### 4.11 Settings section & subsection NESTING — `SettingsView.swift` (the called-out win)

This is a signature surface; specify it precisely.

**Group** (`.set-group`, margin-bottom 28):
- **Group label** (`.set-group-label`): mono 9.5pt, `+0.22em` tracking, UPPERCASE, `ink4`, **followed by a trailing 1px hairline rule** that fills the remaining width (`::after { flex:1; height:1px; background: line }`). In SwiftUI: `HStack { Text(label.mono.upper) ; Rectangle().fill(line).frame(height:1) }`. Existing `settingsGroup(_:systemImage:)` renders a `Label` in sans secondary — restyle to mono + add the trailing rule.
- **Card** (`.set-card`): radius 12, 1px `line`, `g130` fill, `overflow hidden`. Rows inside.
- **Row** (`.set-row`): padding `13 16`, gap 14; label-block left (label sans 13pt medium `ink`; optional helper sans 11pt `ink3`, max ~52ch); **controls right-aligned** (`.set-controls`, gap 10). Rows separated by 1px `lineFaint` (`set-row + set-row`).

**Subsection** (`.nested`): indented, **on a 1px LEFT rail**.
- Container: margin `0 16 14 16`, `padding-left 16`, **`border-left: 1px line2`** (the rail).
- Optional **micro-caption** (`.nested-cap`): mono 9.5pt `ink4` (e.g. `UPDATES`, or `You're on v0.5.1 (build 61)`), padding `4 0 2`.
- **Nested rows** (`.nested-row`): padding `10 0`, gap 12; nested label sans 12pt `ink2`; right-aligned control. Separated by 1px `lineFaint`.

The hierarchy the user perceives: **Section (mono label + rule) → Card → Row → right-aligned mono value/control**, and where deeper grouping is needed, **Subsection on a left rail with its own micro-caption**. Quiet hours → Active window time control is the canonical nested example; App → Updates is the canonical micro-caption subsection.

### 4.12 Diagnostics checklist — `SettingsView.swift` (Diagnostics group) / `HealthPane.swift`

Inside a `set-card`. Each row (`.diag-row`, padding `11 16`, mono 12pt, separated by `lineFaint`): a 16×16 circle check (1px `greenDim` border, `green` check glyph 9×9) + name (`ink`) + **mono value right-aligned in `green`** (e.g. `Granted ✓`, `Running ✓`, `Connected ✓`, `Configured ✓`). Footer (`.diag-foot`, padding `14 16 2`): secondary buttons `Export diagnostic log`, `Reveal logs folder` (§4.10). `HealthPane` is the same checklist as a standalone pane — apply identical styling; its values become mono.

### 4.13 Home status card — `HomePane.swift`

**Card** (`.status-card`): radius 12, 1px `line`, `g130` fill.
- **Head** (`.status-card-head`, padding `12 18`, bottom border `line`): left mono label `SYSTEM STATUS` (9.5pt `+0.2em` UPPERCASE `ink4`); right mono `4 checks · updated 12s ago` (10pt `ink3`).
- **Rows** (`.status-row`, padding `15 18`, gap 14, separated by `lineFaint`): 8px status dot + name (sans 13.5pt medium `ink`) + **mono value right-aligned** (11.5pt; tinted `green`/`amber` per state, e.g. `Running`, `2 awaiting approval`).
- **Home foot** (`.home-foot`): radius 12, 1px `line`, `g100` fill, padding `13 16`; a 15px `blue` star icon + sans `ink2` text with a bold `Labs` (`Open Labs in the sidebar to generate your Texting Wrapped.`).

> Current `HomePane.statusCard` already has the right structure (dot + title + secondary detail). Restyle: card → `g130` + `line`; the detail value → **mono**, tinted per `Tone`; add the mono head row (`SYSTEM STATUS` + check count). Page title → 26pt bold.

---

## 5. Theming

- **Light is the default.** Do not derive the initial theme from `prefers-color-scheme` implicitly — the app should default to Light and let the user opt into Dark (mirror the prototype, which sets `data-theme="light"` explicitly). If the app already follows the system appearance, that's acceptable for v1 as long as **both** themes render correctly; the explicit Light-default is the design intent (confirm rollout in §7).
- **Dark is first-class**, not an afterthought: every token in §2.1 has a §2.2 counterpart. No hard-coded colors anywhere — all surfaces, ink, hairlines, and status colors resolve through `DS.Color`.
- **Mechanism (recommended):** `colorScheme`-keyed `DS.Color` accessors (§2.3). Read `@Environment(\.colorScheme)` in each view (or thread a `Theme` from the shell). Asset-catalog Color Sets with Any/Dark appearances are an acceptable alternative; keep the `DS.Color.x` call-site API identical either way.
- **Cross-fade** surfaces on theme flip at 0.18s (§2.8), respecting reduced-motion.
- **The accent and the iMessage gradient are theme-independent**; the iMessage/WhatsApp *incoming* surfaces and WhatsApp outgoing switch per theme (§2.2 note). Verify both themes against the prototype's Light/Dark toggle.

---

## 6. Codex Implementation Handoff

Canonical visual reference: open `design/concepts/direction-operator.html` and toggle Light/Dark. Where prose and pixels diverge, **the token tables in §2 are authoritative**; for un-specified geometry, **match the prototype**.

**Build order (each step names the real files):**

**(a) Tokens layer — `DesignSystem/` (new folder under `menubar/Sources/MessagesForAIMenu/`).**
Add: `DSColor.swift` (every token from §2.1/§2.2 as `colorScheme`-keyed accessors), `DSFont.swift` (§2.4 `DS.Font` + tracking/case helpers), `DSMetrics.swift` (spacing §2.5, radii §2.6), `DSModifiers.swift` (`.hairline()`, `.dsCard()` from §2.7). No view changes yet — just the layer. Verify it compiles (`cd menubar && swift build`).

**(b) Shell + sidebar — `ConsoleView.swift`.**
Restyle sidebar fill (`g080`), 1px right edge, wordmark, nav rows (default/hover/active with 2px blue rail + blue glyph, §4.1), count badges (§4.4), Settings attention dot, LABS group header (§4.1), sidebar foot. Add the missing Home/Scheduled/Health nav rows + route them to `HomePane`/`ScheduledPane`/`HealthPane` (see §3 IA note / §7). Centered mono titlebar title (§4.2).

**(c) Hero: DraftsPane + PendingMessageBubble — `DraftsPane.swift` (+ `ContextBubbleView.swift`, `InducedDraftBadge.swift`, `PlatformStyling.swift`). Highest value — do this carefully.**
Thread-list rows → §4.3 (avatar + mono handle + selected rail). `CountChip`/`PlatformBadge` → §4.4 (radius-2, mono, blue draft chip). Transcript bubbles (`ContextBubbleView`, `ConfirmedMessageBubble`) → §4.5 native bubbles (18 radius + tail, iMessage gradient, WhatsApp tokens + ticks, mono timestamps). **`PendingMessageBubble`** → §4.6/§4.7: solid iMessage-blue gradient bubble + tail, mono "AI DRAFT · HOLD TO SEND · iMessage" tag, external hold rail (track + `blue` fill + 2px `blueEdge` edge + mono `HOLD · 0.55s` / `55%` readout + hint), neutral graphite icon buttons. **Keep all gesture/timing logic** (`beginHold`/`cancelHold`/`fireTask`, 1.0s/2.0s) — visuals only.

**(d) Settings nesting — `SettingsView.swift`.**
`settingsGroup` → mono group label + trailing hairline rule (§4.11). Cards → `dsCard`. Rows → label-block + right-aligned controls + `lineFaint` separators. Subsections (Quiet hours→Active window; App→Updates) → left-rail `.nested` + micro-caption. `SwitchButton` → 38×22 **neutral graphite ON** (§4.10). Masked API key + time + select controls → mono (§4.10). Diagnostics → §4.12.

**(e) Home / Health / Scheduled — `HomePane.swift`, `HealthPane.swift`, `ScheduledPane.swift`.**
Status cards → `dsCard` + mono values + token-colored dots (§4.13, §4.9). Scheduled rows → §4.8 + mono amber held-reason chips. Health checklist → §4.12.

**(f) Dark theme pass.**
Audit every view for hard-coded colors / `NSColor` semantic colors / `Color.accentColor` on surfaces; route all through `DS.Color`. Toggle Dark and compare against the prototype's Dark mode. Restyle the Labs views (`TextingVoiceView`, `DontGhostView`, `EQView`, `TextingAnalyticsView`, `WrappedToolView`, `BirthdayToolView`) and `AutomationsView` enough that they don't look out-of-system (tokens + typography), even though they aren't specced row-by-row here.

**Verify after each Swift step:**
```
(cd menubar && swift build && swift test)
(cd menubar && bash scripts/dev-install.sh)   # rebuild + reinstall the .app to eyeball it
```

---

## 7. Open Questions & Non-Goals

**Open questions (resolve with product before/while building):**

1. **Hold durations** — spec says 1.0s default / 2.0s induced; the live product matches (`PendingMessageBubble.holdDuration`). Confirm these are still current and that scheduled "send now" uses the same 1.0s. (My read of the code: yes.)
2. **Home/Scheduled/Health nav rows** — the prototype shows them; `ConsoleView` currently omits them from the top group and routes those cases to fallbacks. Recommended: add the rows (panes already exist). Confirm this IA addition is in-scope for the restyle.
3. **Does Dark ship in v1?** Both themes are fully tokenized regardless. Decide whether the toggle is user-exposed at launch or Dark follows system only. (No blocker either way — tokens are complete.)
4. **Light-default vs. follow-system** — design intent is explicit Light default with opt-in Dark. If the app currently follows system appearance, confirm whether to force Light-default or accept system-following for v1.
5. **WhatsApp tick glyph** — the prototype uses a custom double-check; confirm whether to bundle a glyph asset or compose from SF Symbols (`checkmark.shield`/doubled `checkmark`). Cosmetic.
6. **Avatar monogram source** — restyle adds a 2-letter monogram to thread rows; confirm derivation (initials of `displayName`, fallback to handle) and the WhatsApp green-tinted variant.

**Non-goals (explicit):**
- No new features, screens, flows, or data. This is a **restyle**.
- No change to send/approval behavior, hold timing, daemon wiring, draft schema, or the FDA/peer-auth architecture.
- No bundled webfonts or third-party UI frameworks — native SF Pro/SF Mono and SwiftUI only.
- No glows/gradients-on-chrome/decorative cards (see §1 anti-patterns) — adding any is a regression.
- The Labs tool views get a **token/typography pass** (step f) but are not redesigned screen-by-screen in this spec.
