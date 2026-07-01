# Analytics & Observability Recommendation — Messages for AI

**Prepared:** June 5, 2026
**Scope:** A single privacy-safe analytics/observability platform for a notarized, open-source macOS desktop app (Swift) plus its marketing site (messagesfor.ai), under a hard rule that the platform must never receive message bodies, recipients, contact names, phone numbers, emails, Apple IDs / WhatsApp IDs / chat IDs, prompts, drafts, or API keys.

> All prices are June 2026 estimates from official pricing pages and should be treated as approximate — verify on the vendor's pricing page before committing. Where a vendor's pricing page could not be fetched directly, that uncertainty is flagged inline.

---

## 1. The headline recommendation

**If you can pick only one platform: choose PostHog (EU Cloud), configured in strict manual-capture mode.**

This is the same conclusion you were leaning toward — and after objectively comparing it against seven alternatives, it holds up, but for specific reasons that matter for *this* product, not because it's the default popular choice.

**Why PostHog wins the one-platform test:** it is the only candidate that can credibly cover *all seven* of your coverage needs from a single account — marketing-site web analytics, install/open events, product usage, feature adoption, error/exception tracking, release/version tracking, and privacy-safe cohorts/funnels ([PostHog Web Analytics](https://posthog.com/docs/web-analytics), [Error Tracking](https://posthog.com/docs/error-tracking), [Funnels](https://posthog.com/docs/product-analytics/funnels)). Every other privacy-first tool covers a subset and forces a second tool.

It also satisfies your hardest constraints when configured correctly:

- **Manual-only capture is fully supported.** On the Apple SDK, element-interaction autocapture is *disabled by default*, and there is a server-side HTTP ingestion API (`/i/v0/e` and `/batch`) that needs no SDK at all — so the app can POST only allowlisted metadata ([Capture API](https://posthog.com/docs/api/capture), [Autocapture docs](https://posthog.com/docs/product-analytics/autocapture)).
- **Anonymous by construction is possible.** Adding `"$process_person_profile": false` to every event means no person profiles are ever created — only event counts ([Capture API](https://posthog.com/docs/api/capture)).
- **EU data residency** via `eu.i.posthog.com` (Frankfurt), which also disables IP capture by default for new projects ([GDPR compliance](https://posthog.com/docs/privacy/gdpr-compliance)).
- **Session replay is off by default** and stays off unless you explicitly enable it ([iOS session replay](https://posthog.com/docs/session-replay/ios)).
- **A genuinely generous free tier** — 1,000,000 analytics events and 100,000 exceptions per month, resetting monthly, no credit card — which a small OSS app is unlikely to exceed for a long time ([PostHog pricing](https://posthog.com/pricing)).
- **A first-class official MCP server** at `mcp.posthog.com/mcp` with an `execute-sql` (HogQL) tool and native Claude Code / Claude Desktop / Codex integration, so you (and your AI assistants) can answer product questions later without building a query layer ([PostHog MCP](https://posthog.com/docs/model-context-protocol), [Build insights with MCP](https://posthog.com/docs/product-analytics/build-insights-mcp)).

**The one important caveat:** PostHog's macOS support is real but under-documented. The Swift SDK ([posthog-ios](https://github.com/PostHog/posthog-ios)) declares macOS 10.15+ in its `Package.swift` and the [Swift Package Index](https://swiftpackageindex.com/PostHog/posthog-ios) confirms macOS builds, but PostHog's own docs are entirely iOS-centric with zero macOS guidance. The clean way to neutralize this risk — and the safest possible privacy posture — is to **skip the SDK on the desktop app entirely and send allowlisted events over the HTTP API**, treating the app as a thin telemetry client. The SDK can still be used on the marketing site's JavaScript.

**The one default you must change:** PostHog's web JavaScript SDK has autocapture *on* by default, which can capture text typed into form fields. On messagesfor.ai you must explicitly set `autocapture: false`, `capture_pageview` manual, and cookieless/memory persistence before deploying ([Autocapture docs](https://posthog.com/docs/product-analytics/autocapture), [JS persistence](https://posthog.com/docs/libraries/js/persistence)).

---

## 2. Runner-up (if the one-platform rule is relaxed)

**TelemetryDeck + Sentry** — a privacy-first pair with non-overlapping jobs.

If you decide one platform isn't worth the configuration discipline PostHog demands, this is the cleanest two-tool stack, and arguably the most "default-safe":

- **[TelemetryDeck](https://telemetrydeck.com)** for product analytics, feature adoption, funnels, retention, and version tracking. It is Swift-native with first-class macOS support, EU-hosted (Germany), and *architecturally* incapable of leaking content: it has **no autocapture**, double-hashes identifiers on-device, stores no IP/cookies/PII, and only ever transmits the signals your code explicitly fires ([Swift SDK](https://github.com/TelemetryDeck/SwiftSDK), [anonymization](https://telemetrydeck.com/docs/articles/anonymization-how-it-works/), [architecture & security](https://telemetrydeck.com/use-case/architecture-security/)). Free tier ~100,000 signals/month ([WWDC25 post](https://telemetrydeck.com/blog/wwdc25/)).
- **[Sentry](https://sentry.io)** *only* for symbolicated crash/exception reporting and release health — the one thing TelemetryDeck and PostHog don't do well. The [sentry-cocoa SDK](https://github.com/getsentry/sentry-cocoa) genuinely supports macOS (note: uncaught NSExceptions require `enableUncaughtNSExceptionReporting = true`), `sendDefaultPii` defaults to false, `beforeSend` lets you scrub any payload before it leaves the device, EU region (Frankfurt) is available, and the [OSS Sponsorship plan](https://sentry.io/for/open-source/) gives open-source projects ~5M errors/month for free ([macOS setup](https://docs.sentry.io/platforms/apple/guides/macos/)).

This pairing leans on each tool's strongest, most privacy-aligned capability. The trade-off is two dashboards, two SDKs, and two privacy reviews instead of one — which is exactly the cost your one-platform preference is trying to avoid.

A lighter single-tool runner-up worth knowing about: **[Aptabase](https://aptabase.com)** is purpose-built for native desktop/mobile apps, has a true first-party Swift SDK with explicit macOS sandbox instructions, is fully open-source/self-hostable, and is rigorously anonymous (no fingerprinting, no device IDs) ([aptabase-swift](https://github.com/aptabase/aptabase-swift), [for-swift](https://aptabase.com/for-swift)). It loses to PostHog only because it has **no web analytics, no funnels, no crash reporting, no MAU/retention, and no API/MCP** ([Aptabase gaps](https://aptabase.com)) — so it can't satisfy "one platform for everything."

---

## 3. Do-not-use list (for this product)

| Platform | Why it's wrong for Messages for AI |
|---|---|
| **Vercel Web Analytics** | Web/browser-only, requires a Vercel project, cannot ingest native macOS app events, and has **no query API or MCP** ([Vercel Analytics](https://vercel.com/docs/analytics/quickstart)). Disqualified as a single platform. |
| **Plausible** (as the *only* tool) | Excellent privacy-first *web* analytics, but its Events API is not built for desktop apps (you'd manufacture fake URLs and manage IP/User-Agent headers), and it has no crash reporting, no native app SDK, and its Stats API/MCP are Business-tier and community-built ([Plausible Events API](https://plausible.io/docs/events-api), [data access](https://plausible.io/docs/data-access)). Fine as a marketing-site complement, not as the platform. |
| **Amplitude** | Strong product analytics, but **no self-hosting**, session autocapture and IP retention are on by default (must disable via `disableTrackIpAddress()`), no crash reporting, and the free tier is MTU-capped (~10K MTU) — a worse fit than the alternatives for an anonymous OSS app ([Amplitude security](https://amplitude.com/security-and-privacy)). |
| **Mixpanel** | Similar story to Amplitude (more privacy-conservative — discards IP after geolocation — but still **no self-hosting and no crash reporting**) ([Mixpanel privacy](https://docs.mixpanel.com/docs/privacy/protecting-user-data)). Capable, but it forces a second tool and offers nothing PostHog/TelemetryDeck don't. |
| **Any tool with session replay turned on** (PostHog replay, Sentry mobile replay, FullStory, Datadog) | A messaging app's screens contain message content. Replay — even with masking — is an unacceptable exfiltration risk here. Sentry replay is iOS-only anyway ([Sentry session replay](https://docs.sentry.io/platforms/apple/session-replay/)); PostHog replay on macOS SwiftUI requires `screenshotMode = true`, which captures real pixels ([iOS replay](https://posthog.com/docs/session-replay/ios)). **Default answer: no replay.** |
| **Firebase / Google Analytics** | Not requested and not appropriate: Google data-sharing posture, weak EU residency story, and consent-banner overhead conflict directly with your privacy positioning. |

---

## 4. Answers to your 10 questions (quick-reference matrix)

| # | Question | Answer |
|---|---|---|
| 1 | One platform? | **PostHog (EU Cloud)**, manual-capture only. |
| 2 | Can it cover all 7 areas? | **Yes.** Web analytics ✅, install/open ✅, usage ✅, adoption ✅ (+ feature flags), errors ✅ (100K/mo free), version tracking ✅ (via event props), cohorts/funnels ✅ (anonymous-safe). |
| 3 | First-class native macOS/Swift? | **TelemetryDeck** and **Aptabase** are genuinely first-class. **Sentry** is strong. **PostHog/Amplitude/Mixpanel** declare macOS in `Package.swift` but document iOS only. **Plausible/Vercel** are not native. |
| 4 | Official SDK / documented macOS pattern? | TelemetryDeck ✅, Aptabase ✅, Sentry ✅ (has a macOS setup page). PostHog/Amplitude/Mixpanel: SDK supports macOS, docs don't. |
| 5 | Server-side / manual allowlisted capture? | **PostHog** ✅ (`/i/v0/e`, `/batch`), **Amplitude** ✅ (HTTP V2), **Mixpanel** ✅ (`/import`), **Plausible** ✅ (Events API), **TelemetryDeck/Aptabase** ✅ (manual-only by design). |
| 6 | Self-hosting / data residency? | Self-host: **PostHog** (Docker, no paid support), **Aptabase**, **Plausible**, **Sentry**, Matomo/Umami. EU residency without self-host: **TelemetryDeck** (always EU), PostHog/Sentry/Amplitude/Mixpanel (EU region option). |
| 7 | Session replay — disable it? | PostHog (off by default), Sentry (iOS-only), Amplitude/Mixpanel (web-only). **Disable everywhere. Default = no.** |
| 8 | MCP/API for Claude/Codex? | **PostHog** ✅ official MCP + HogQL. **Amplitude** ✅ + **Mixpanel** ✅ official MCP. **Sentry** ✅ official MCP. TelemetryDeck (TQL API + community MCP), Plausible (community MCP), Aptabase/Vercel ❌. |
| 9 | Cost shape (small OSS, low-med usage)? | See cost table §7. PostHog effectively **$0** within free tier. |
| 10 | Privacy/security disqualifiers? | Replay-on, web autocapture-on, identifying users by email/phone/chat-ID, IP retention by default, no EU residency. See §8. |

---

## 5. Proposed privacy-safe event taxonomy

Design rule: **categorical and numeric only.** Every property value must be a fixed enum, a count, a boolean, a coarse duration bucket, or a semver string. No free text, no identifiers, ever. Use a random per-install UUID as the only "user" key, and prefer anonymous events (`$process_person_profile: false`).

### Lifecycle & releases
| Event | Safe properties |
|---|---|
| `app_installed` | `app_version` (semver), `os_version`, `release_channel` (`stable`/`beta`), `update_source` (`github`/`sparkle`) |
| `app_opened` | `app_version`, `days_since_install` (bucketed: `0`,`1-7`,`8-30`,`30+`) |
| `app_updated` | `from_version`, `to_version`, `via` (`sparkle`/`manual`) |
| `telemetry_opt_in` / `telemetry_opt_out` | `surface` (`onboarding`/`settings`) |

### Connections (presence only — never the account)
| Event | Safe properties |
|---|---|
| `source_connected` | `source` (`imessage`/`whatsapp`) — **never** the handle, number, or ID |
| `permission_granted` / `permission_denied` | `permission` (`full_disk`/`contacts`/`automation`) |

### Core workflows
| Event | Safe properties |
|---|---|
| `draft_staged` | `draft_length_bucket` (`<50`/`50-200`/`200+` chars) — bucket only, **never the text** |
| `draft_approved` / `draft_discarded` | `had_edits` (bool) |
| `message_send_scheduled` | `schedule_horizon_bucket` (`<1h`/`1-24h`/`24h+`) |
| `message_sent` | `source`, `was_scheduled` (bool) — **no recipient, no body** |
| `assistant_invoked` | `assistant` (`claude`/`codex`), `workflow` (enum) — **never the prompt** |

### Labs / exploratory features (feature adoption)
| Event | Safe properties |
|---|---|
| `lab_opened` | `lab` (`texting_style`/`dont_ghost`/`eq`/`texting_analytics`) |
| `lab_completed` | `lab`, `duration_bucket` |
| `feature_used` | `feature` (enum), `app_version` |

### Diagnostics (allowlisted error categories only)
| Event | Safe properties |
|---|---|
| `error_occurred` | `error_category` (enum: `permission`/`network`/`parse`/`send_failed`), `app_version`, `os_version` — **no stack trace, no message, no paths** |

**Hard exclusions enforced at the serialization layer:** message bodies, recipients, contact names, phone numbers, emails, Apple/WhatsApp IDs, chat IDs, prompt/draft text, API keys, file paths, raw timestamps tied to a person. Build a single `track(event:, props:)` wrapper that validates every key against the allowlist and rejects anything else — this makes a leak a compile/test failure rather than a runtime accident.

---

## 6. Sample macOS implementation plan (PostHog, HTTP-first)

**Phase 1 — Telemetry gate & client**
1. Add a Settings toggle: **"Share anonymous usage data"**, default **OFF** (opt-in). Persist the choice; gate all sends behind it.
2. Generate a random `install_id` (UUID v4) stored in the app's container. Never derive it from any account or device identifier.
3. Build a thin Swift `TelemetryClient` that POSTs to `https://eu.i.posthog.com/i/v0/e` (single) or `/batch` (batched), with `api_key`, `distinct_id = install_id`, `event`, `properties`, and `"$process_person_profile": false` on every event ([Capture API](https://posthog.com/docs/api/capture)).

**Phase 2 — Allowlist enforcement**
4. Implement `track(_ event: AnalyticsEvent, props: [AllowlistedKey: AnalyticsValue])` where `AnalyticsEvent` and `AllowlistedKey` are enums (taxonomy §5). The type system prevents arbitrary strings. Add a unit test asserting no payload ever contains a denylisted key or a `String` free-text value.
5. Batch events locally, flush periodically and on quit; drop silently on failure (telemetry must never block the user).

**Phase 3 — Coverage rollout**
6. Instrument lifecycle, connection-presence, workflow, and lab events per the taxonomy.
7. Send `app_version` / `release_channel` on every event so PostHog can do version tracking and per-release funnels (this is your Sparkle release-tracking story) ([Web Analytics](https://posthog.com/docs/web-analytics)).
8. For diagnostics, send only allowlisted `error_occurred` categories. **Do not send stack traces remotely** — keep crash/diagnostic export local (an in-app "Export diagnostics" file the user can choose to attach to a GitHub issue). Revisit remote crash reporting (Sentry, OSS plan) only if local reports prove insufficient.

**Phase 4 — Marketing site (messagesfor.ai)**
9. Add the PostHog JS snippet with `autocapture: false`, `capture_pageview: false` (call manually), `cookieless_mode: 'always'` or `persistence: 'memory'`, `disable_session_recording: true`, pointed at `eu.i.posthog.com` ([JS persistence](https://posthog.com/docs/libraries/js/persistence), [cookieless](https://posthog.com/tutorials/cookieless-tracking)).
10. Track only `pageview`, `download_clicked`, and `docs_viewed` — no form-field capture.

**Phase 5 — Verify & wire up AI querying**
11. Run the app behind a network proxy (e.g., Proxyman/Charles) and inspect every outbound payload against the allowlist before shipping. This is your final privacy gate.
12. Install the PostHog MCP server (`npx @posthog/wizard@latest mcp add`) so Claude/Codex can later answer product questions via HogQL ([PostHog MCP](https://posthog.com/docs/model-context-protocol)).

---

## 7. Cost estimate table (June 2026, small OSS app, low-to-medium usage)

| Platform | Free tier | First paid step | Effective cost for you | Source |
|---|---|---|---|---|
| **PostHog** (recommended) | 1M events + 100K exceptions/mo | PAYG $0 base, ~$0.00005/event over 1M | **~$0** — well within free tier | [pricing](https://posthog.com/pricing) |
| **TelemetryDeck** | ~100K signals/mo (~3.3K MAU) | Starter ~€9/mo (1M signals) | ~$0–€9/mo *(price est., page not directly fetchable)* | [WWDC25](https://telemetrydeck.com/blog/wwdc25/) |
| **Sentry** | Developer (small) | Team ~$26/mo; **OSS Sponsorship: ~5M errors/mo free** | **~$0** via OSS plan | [OSS plan](https://sentry.io/for/open-source/) |
| **Aptabase** | 20K events/mo | ~$9–19/mo *(est., verify)* | ~$0 if under 20K | [aptabase.com](https://aptabase.com) |
| **Plausible** | 30-day trial only | Starter ~$9/mo (10K pv); Stats API needs Business ~$19/mo | ~$9–19/mo (web only) | [pricing](https://plausible.io/docs/subscription-plans) |
| **Amplitude** | ~10K MTU / ~2M events | Plus paid; Startup Scholarship 1yr free | $0 first year if eligible | [startups](https://amplitude.com/startups) |
| **Mixpanel** | 1M events/mo | Growth paid; Startup 1yr free (1B events) | $0 first year if eligible | [startup program](https://docs.mixpanel.com/docs/pricing/startup-program) |
| **Vercel Analytics** | 50K events/mo (Hobby) | $3/100K events (Pro, +$20/mo base) | N/A — can't do app events | [pricing](https://vercel.com/docs/analytics/limits-and-pricing) |

**Bottom line on cost:** with PostHog you are realistically paying **$0** for a long time. Self-hosting only makes sense if you want zero third-party data flow at all — and it costs you a ~4 vCPU / 16 GB VM plus all maintenance, with paid features unavailable ([self-host](https://posthog.com/docs/self-host)).

---

## 8. Privacy/security disqualifiers (what would make a platform inappropriate)

1. **Session replay on a messaging app** — screens show message content; masking is not a sufficient guarantee. Disqualifying unless off.
2. **Autocapture on by default** capturing form/text inputs (PostHog web JS) — must be explicitly disabled before any deploy.
3. **Identifying users by email, phone, Apple/WhatsApp ID, or chat ID** as `distinct_id` — use only a random install UUID.
4. **IP retention by default** without an easy off switch (Amplitude retains IP unless disabled) — prefer EU region / IP-off.
5. **No EU residency option** for a privacy-positioned product.
6. **Stack traces / breadcrumbs sent remotely** — these routinely leak file paths and variable values; keep diagnostics local by default.

---

## 9. The "Sitter / PostHog decision" — where it applies and where it doesn't

I want to be precise here because this is where teams most often over- or under-apply received wisdom.

**Where the PostHog-vs-others framing *does* apply to you:** the choice of a single, broad product-analytics platform that can also do web analytics, feature flags, and exception tracking. For a product team that wants one dashboard, one query layer, and an AI-queryable data store, PostHog genuinely is the strongest single answer — and that logic transfers cleanly to Messages for AI.

**Where it does *not* apply — and where a generic "just use PostHog" recommendation breaks down for this product:**

- **The default config is wrong for you.** Generic PostHog advice assumes autocapture and replay are desirable. For a messaging app they are *liabilities*. Your win condition is the opposite of the default: autocapture off, replay off, anonymous events, HTTP-only on desktop.
- **The autocapture value proposition is inverted.** The usual argument *for* PostHog over a manual tool like TelemetryDeck/Aptabase is "autocapture saves instrumentation work." For you, autocapture is a risk to be eliminated — which means PostHog's headline advantage over the privacy-first tools largely *evaporates*, and the decision narrows to coverage breadth and MCP, not convenience.
- **Crash reporting is not really solved by either side.** PostHog's exception tracking and TelemetryDeck's error categorization both fall short of Sentry-grade symbolicated crash reports. The privacy-correct answer for this product is to **not** chase remote crash reporting at all initially — keep diagnostics local — so this dimension shouldn't drive the platform choice the way it would for a typical consumer app.
- **macOS-native quality is a real differentiator the generic framing ignores.** If native-Swift fidelity and zero-config privacy mattered more to you than single-platform coverage, the honest answer would flip to **TelemetryDeck or Aptabase**, not PostHog. The only reason PostHog still wins is your explicit one-platform constraint plus the web-analytics + MCP requirements.

**Net:** PostHog is the right *one* platform for you — but for the breadth + MCP reasons, deliberately operated in a stripped-down, manual, anonymous mode that looks almost nothing like a default PostHog deployment. If you ever relax the one-platform rule, the privacy-purist answer (TelemetryDeck + Sentry, or Aptabase self-hosted) becomes equally defensible.
