# Messages for AI: Red-Team Threat Model

**Date:** 2026-06-07
**Repo:** Sunrise-Labs-Dot-AI/messages-for-ai
**Scope:** Full product (menubar Swift app, iMessage MCP + daemon, WhatsApp MCP + Baileys daemon, skills, marketing site, plugin)
**Lens:** Code security, privacy, legal liability, and "1M users overnight, worldwide"
**Method:** Four parallel component audits (Claude subagents over the source), a maintainer solo-operator analysis, and an independent parallel review by Codex. Findings converged across reviewers, which raises confidence they are real rather than one model's artifact.
**Issues filed:** #76 through #93 (see mapping below).

> Note: the legal sections are an engineer's read, not legal advice. Several points (wiretap applicability to already-received messages, the GDPR household-exemption boundary) are genuinely unsettled. Treat them as "get counsel" flags.

---

## Bottom line

The engineering is more security-aware than most indie macOS apps: SQL is fully parameterized, AppleScript sends are argv-safe (no injection), the Sparkle update chain is correctly signed, untrusted message bodies are wrapped, symlink and ownership hardening is thorough, session credentials are AES-GCM encrypted, there is no covert telemetry. The danger is not sloppy code. It is a small number of structural trust-boundary choices that hold at 1k users and shatter at 1M:

1. **The approval gate, which is the entire product promise, is enforced by unauthenticated JSON files on local disk** (#77). Any process running as the user, including a prompt-injected AI agent that already has file write, can forge "approved" and send messages with no human action.
2. **The product ships an unofficial WhatsApp client (Baileys) that fingerprints itself to Meta** (#85), with the ban risk disclosed in the repo but not on the site users actually read. 1M of these appearing overnight is a Meta-detectable event that bans users' primary numbers and invites legal action.
3. **The bundle says "No data leaves this Mac" while the Labs features POST message bodies to Anthropic and OpenAI** (#80). That is a verifiably false privacy claim in shipped metadata.
4. **Latent at scale: the Sparkle EdDSA signing key is a master key for code execution with Full Disk Access on every install** (#93), and it lives in one person's keychain.

---

## The kill chain (the finding that matters most)

These compose into a self-propagating attack rather than isolated bugs:

> Attacker texts a victim a crafted message. The victim's agent reads it via a read tool (bodies are wrapped in `<untrusted_content>`, but that is a soft, model-defeatable hint, `mcps/.../tools/_untrusted.ts:7`). The injection persuades the agent to stage a reply to the victim's contacts. Because approval is forgeable on disk, the message sends. It carries the same injection. It spreads.

Three independent paths reach "send without a human":

- **iMessage send gating lives entirely in the MCP process** (the agent's own trust domain), not the FDA daemon. `require_approval` is read fresh from `settings.json` each call (`mcps/imessage-drafts/src/storage/settings.ts:51-69`); min-age and daily cap come from MCP env vars that honor `0 = disabled` (`src/tools/drafts.ts:28`, `src/imessage/audit.ts:144-169`). Whoever controls the agent's env or settings turns the gate off. (#78)
- **The menu bar auto-sends any automation or draft file whose "approved" bit is set**, and that bit is just a field in a user-writable JSON file with no signature or provenance. Worse, defaults fail open: TS defaults a missing `approvalStatus` to approved (`src/storage/automations.ts:82-85`) and Swift treats anything not `.pending` as approved (`menubar/.../AutomationStore.swift:163`). (#77)
- **The iMessage path bypasses every daemon-side rate limit**: it shells `osascript` directly (`menubar/.../DraftSender.swift:138-201`), so no min-age, burst cap, daily cap, or induced-contact block applies. The induced-by-unknown-contact flag only changes a color and doubles a hold timer. (#78)

The local trust boundary is also breakable directly: peer-auth uses `LOCAL_PEERPID` then shells out to `codesign` twice (`src/daemon/peer-auth.ts:103-157`, `src/daemon/peer-pid.ts:59-72`), a classic PID-reuse TOCTOU that lets a local process read the entire chat.db and AddressBook (#79). And the daemon read RPCs do not re-enforce the `since`/`contact_filter`/limit privacy bounds (those live only at the MCP schema layer), so winning that race yields an unbounded history dump (#78).

---

## Severity map to issues

| Issue | Sev | Finding |
|-------|-----|---------|
| [#76](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/76) | P0 | Cloud forced-upgrade + remote kill switch (the meta-control; maintainer-requested) |
| [#77](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/77) | P0 / Critical | Approval gate forgeable via on-disk JSON + fail-open defaults |
| [#78](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/78) | P0 / Critical | Send gate + read bounds enforced in MCP layer, not the FDA daemon |
| [#79](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/79) | P0 / High | Peer-auth PID-reuse TOCTOU |
| [#80](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/80) | P0 / High | False "No data leaves this Mac" vs Labs egress |
| [#81](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/81) | P1 / High | WhatsApp messages.db plaintext at rest |
| [#82](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/82) | P1 / High | Keychain wrap-key has no `-T` ACL (account hijack) |
| [#83](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/83) | P1 / Med-High | FDA app follows log-file symlinks (confused deputy) |
| [#84](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/84) | P1 / Med | WhatsApp daemon + QR session lack inbound frame cap |
| [#85](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/85) | P1 / High@scale | Baileys ban risk: consent gate, site disclosure, drop fingerprint |
| [#86](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/86) | P1 / High@scale | Distribution: 147MB updates, single host, no cost cap |
| [#87](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/87) | P1 / Med | Untrusted-content: unwrapped sender names + defeatable escape |
| [#88](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/88) | P1 / Med | Duplicate-send race (missing cross-process lock) |
| [#89](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/89) | P1 / Med | No telemetry = operational blindness |
| [#90](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/90) | P2 / Low-Med | Scheduled-pane "Send now" not hold-to-fire |
| [#91](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/91) | P2 / Low | Robustness batch (attachment_meta, automation linearization, dir 0700) |
| [#92](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/92) | P2 / High legal | Legal foundation: ToS/EULA, GDPR/CCPA/DSAR, COPPA/wiretap |
| [#93](https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/issues/93) | P2 / High continuity | Business continuity: breach runbook, key escrow, MoR, LLC |

---

## Findings by component

### iMessage MCP + chat.db daemon (`mcps/imessage-drafts/`)
- **C / #79:** PID-reuse TOCTOU in peer auth (`src/daemon/peer-auth.ts:103-157`, `src/daemon/peer-pid.ts:59-72`). `LOCAL_PEERPID` does not bind the connected socket to the verified image; two slow `codesign` shell-outs widen the window. Fix with a connection-pinned audit token or a per-boot shared secret.
- **C / #78:** Send gate is MCP-side only; `require_approval` (`settings.ts:51-69`), min-age and daily cap (`drafts.ts:28`, `audit.ts:144-169`) are all env/settings-overridable in the agent's trust domain. Daemon has no send method, so the only surviving defense is the one-time macOS Automation prompt.
- **H / #88:** Daily-cap and duplicate-send guards are non-atomic read-modify-write across MCP and menu bar; the file lock is acknowledged-missing (`drafts.ts:259-320,402`).
- **M / #91:** MCP-side `ensureDir` calls omit `mode`, so `~/.messages-mcp` can be created 0755 if the MCP wins the create race (`settings.ts:45`, `drafts.ts:101`) vs daemon 0700 (`daemon/index.ts:18-19`).
- **Verified clean:** SQL fully parameterized with escaped LIKE (`src/chatdb/queries.ts`); AppleScript passed as argv, not interpolated (`src/imessage/send.ts:43-70`), so no AppleScript injection; RPC capped at 1MB; typedstream decoder bounds-checked; thorough symlink/ownership hardening; dev-mode bypass refused on signed binaries.

### WhatsApp MCP + Baileys daemon (`mcps/whatsapp-drafts/`)
- **C / #81:** `messages.db` is plaintext at rest (`src/storage/messages.ts:7-10`), a second unencrypted copy of E2EE history; `audit.db` adds recipient JIDs in cleartext.
- **H / #82:** Keychain wrap-key created with no `-T` ACL (`src/storage/keychain.ts:79-88`, deferred per `:9-13`); `security` invoked via PATH (`keychain.ts:38-44`). Same-user process can unwrap session material and hijack the account.
- **H / #85:** Baileys (`package.json:37-40`) with self-identifying fingerprint `Browsers.macOS("Messages for AI")` (`src/daemon/connection.ts:100-111`). ToS/ban risk disclosed only in `SECURITY.md:111-117`.
- **M / #87:** `sender_name`/`push_name` reach the model unwrapped (`src/tools/threads.ts:49-58`, `src/tools/search.ts:34-41`); `sanitizeIncomingBody` escapes only four exact tags and is defeated by `< /untrusted_content>` whitespace or unicode variants (`src/tools/_untrusted.ts:32-45`).
- **M / #84:** No inbound frame-size cap on the daemon RPC (`src/daemon/server.ts:143-160`).
- **Verified clean:** session creds AES-256-GCM with per-row nonce + auth tag (cipher is sound; weakness is key ACL); SQL parameterized; rate-limit reservation atomic via `BEGIN IMMEDIATE`; the shipped menu-bar spawn passes no dev env so the dev peer-auth bypass is unreachable in production.

### Menu bar app (`menubar/`)
- **C / #77:** Auto-sends approved-looking automation/draft files reloaded from disk every 5s (`AutomationController.swift:27-44`, `ScheduledSendController.swift:70-93`); fail-open defaults (`AutomationStore.swift:163`).
- **H / #80:** `Info.plist` "Local-only utility. No data leaves this Mac." (`scripts/build-release.sh:453-460`) contradicted by Labs egress: EQ excerpts (`EQController.swift:633-650`) POST to Anthropic/OpenAI (`:562-597`), plus `DontGhostController.swift:1271-1348`, `TextingVoiceController.swift:1804-1842`.
- **M / #78:** iMessage path bypasses all daemon safety controls (`DraftSender.swift:138-201`).
- **M / #83:** FDA app follows log symlinks (`WhatsAppDaemonController.swift:391-405`, `IMessageDaemonController.swift:261-275`, `DiagnosticsStore.swift:59-76`).
- **M / #90:** Scheduled-pane "Send now" is one-click, not hold-to-fire (`ScheduledPane.swift:71-74`).
- **Verified clean (supply chain):** Sparkle feed HTTPS and pinned in code overriding user defaults (`UpdaterController.swift:13-16`); `SUPublicEDKey` embedded, build fails closed without a valid key; every enclosure EdDSA-signed; inner binaries Developer-ID signed + notarized, sealed without `--deep`; nothing auto-installs. No MITM hole. The residual risk is theft of the EdDSA private key + Developer-ID cert (#93). No custom URL scheme / no inbound deep-link surface. Diagnostics local-only with PII-key scrubbing. `osascript` argv-safe.

### Skills, research, site (`skills/`, `research/`, `site/`, `.claude-plugin/`)
- **Legal / #92:** No ToS/EULA (only MIT `LICENSE`); Baileys risk absent from the consumer site; no GDPR/CCPA/DSAR framework; third-party non-consenting contact profiling (`skills/.../relationships.py:147-180`, birthday/tier inference); Wrapped `ShareCard` puts a contact name on the shared composite (`skills/.../app.jsx:730-737`) despite a "names redacted" comment two lines up; sensitive-attribute inference ("you text like a 34-year-old", `skills/.../age_estimate.py:164-166`); no two-party/wiretap or COPPA handling.
- **M / #86 related:** the Wrapped artifact pulls four unpkg CDN scripts with no SRI on a page rendering contact names (`skills/.../build_wrapped.py:217-220`).
- **Verified good (calibration):** real no-bodies invariants with exit-code-5 guards and an allowlist layer (`analyze_voice.py:362-379`); no-gender-from-names rule; AddressBook opened read-only/immutable; no network calls in any skill except the unpkg CDN; "we do not sell your message data" stated; business/automated threads filtered out of analytics; people cards excluded from public composites. Privacy engineering here is genuinely careful; the exposure is the legal/disclosure layer, not the code.

---

## Privacy summary
- Plaintext message corpus at scale (#81): locally "fine," but every Time Machine, Backblaze, and iCloud backup centralizes decrypted copies of E2EE conversations. 1M users removes WhatsApp's SQLCipher protection for a million people.
- False local-only claim (#80): the shipped binary's own strings are the liability even though the egress is user-keyed and opt-in.
- Third-party profiling without consent (#92): the people the user texts are named, ranked, scored, and birthday/tier-inferred without any notice or consent mechanism. The household exemption weakens the moment it is a product with a share feature.

## Legal summary (get counsel)
- **Meta / WhatsApp (existential):** Baileys + self-fingerprint + 1M overnight = detectable, attributable, harmful (banned primary numbers across EU/LatAm/India) and standing for Meta to act against Sunrise Labs. Undisclosed on the site removes the informed-consent defense. (#85, #92)
- **No ToS/EULA / liability cap (#92):** for a product that reads entire histories and sends on the user's behalf, nothing stands between the first "the AI texted my boss" incident and the maintainer.
- **GDPR (#92):** message content is Article-9 adjacent; large EU userbase plus non-consenting contacts; no lawful basis, Art. 30 records, DPIA, DPA with providers, or DSAR path. Exposure up to 4% global revenue.
- **US wiretap / two-party consent (#92):** unsettled for received messages; sharper for Labs shipping the other party's messages to a processor.
- **COPPA (#92):** minors in threads, birthday inference on minors, age profiling; no age gate.
- **Apple developer agreement:** chat.db reads + AppleScript-driving at scale + the false privacy string are each plausible triggers for a notarization/Developer-ID review (a kill-switch risk for the whole fleet).

---

## Codex independent review: new findings and reconciliation

Codex confirmed every Critical/High as real and exploitable, and contributed:

**New findings folded in:** the FDA log-symlink confused-deputy write (#83), the missing daemon-layer read bounds that compound the peer-auth race (#78), the fail-open on corrupt `automations.json` (#77), the WhatsApp frame-cap asymmetry (#84), and three robustness items (#91).

**Severity reconciliation:** Codex rated the approval-gate forgery and peer-auth as High rather than Critical, on the grounds they require a local file write or winning a race. The counter that keeps the approval gate at Critical in this product's threat model: the "local process that can write files" is not hypothetical malware, it is the AI agent the product intentionally gives `Write`/`Bash` to, driven by an injectable read path. The precondition is the default operating condition. Codex's downgrade of peer-auth to High-conditional is accepted (TeamIdentifier matching is strong against naive spoofing).

**Cost correction:** Codex read the appcast and found update zips are ~147MB (`site/appcast.xml:11-18`), not the ~20MB first estimated. 1M overnight is roughly 147TB, recurring per update (#86).

---

## Remediation roadmap

**Gate the launch on these (P0):** #76 kill switch and forced min-version (the meta-control that makes everything else survivable), #77 authenticate the approval gate and fix fail-open defaults, #78 move the hard send floor and read bounds into the daemon, #79 connection-pinned peer auth, #80 fix the false local-only claim.

**Before EU/global exposure (P1):** #81 encrypt messages.db, #82 keychain ACL, #83 log symlink hardening, #84 frame cap, #85 Baileys consent + site disclosure + drop fingerprint, #86 CDN + shrink updates, #87 wrap sender names, #88 duplicate-send lock, #89 opt-in health signal.

**Follow-up (P2):** #90 hold-to-fire, #91 robustness batch, #92 legal foundation, #93 business continuity.

The operational analysis behind #76, #86, #89, and #93 is kept in the private strategy repository.
