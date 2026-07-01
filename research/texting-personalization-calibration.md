# Texting Personalization & Calibration Research

**Project:** BetterHuman — "Texting Wrapped" personality/age inference
**Scope:** Private 1:1 and group messaging (SMS, iMessage, WhatsApp, Messenger, Discord, Slack). Local message metadata and aggregate style signals only — **no message bodies stored or uploaded.**
**Compiled:** 2026-06-09
**Framing rule:** All outputs are **playful personality reads**, not clinical, demographic, or deterministic claims. Evidence strength is separated from "vibes" throughout.

---

## 1. Executive Summary

This report grounds the Texting Wrapped archetype and "texting age" engine in the peer-reviewed and reputable-industry evidence base. The headline findings:

**What the research supports well.**
- **Message volume → extraversion** is the single strongest, most-replicated metadata-to-personality link in the field. Phone-log studies predict extraversion from outgoing message/call counts and contact diversity with ~61% accuracy vs. a 39% baseline ([de Montjoye et al. 2013](http://realitycommons.media.mit.edu/deMontjoye2013predicting-citation.pdf); [Stachl et al. 2020, PNAS](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/)).
- **Contact concentration → network breadth/extraversion**, with robust Dunbar-layer structure visible in real call/text logs ([Pollet et al. 2011](https://tvpollet.github.io/pdfs/Pollet_et_al_2011_JID_paper.pdf); [MacCarron, Kaski & Dunbar 2016](https://arxiv.org/abs/1604.02400)).
- **Emoji rate, laugh tokens, terminal punctuation, capitalization, and daily message volume → age/generation** are the strongest age signals, each independently replicated ([Statista 2023](https://www.facebook.com/Statista.Inc/posts/799207609083277/); [Meta Research 2015](https://research.facebook.com/blog/2015/8/the-not-so-universal-language-of-laughter/); [Gunraj et al. 2016](https://www.sciencedirect.com/science/article/abs/pii/S0747563215302181); [Pew 2011](https://www.pewresearch.org/internet/2011/09/19/how-americans-use-text-messaging/)).
- **Reply latency → Big Five** is real but modest, and best documented for *notification interaction delay*, not async text reply specifically ([Stach et al. 2024, Sensors](https://pmc.ncbi.nlm.nih.gov/articles/PMC11053777/)).
- **Tapbacks/reactions are a distinct, legitimate conversational style** — "sequence-closing seconds" that discharge the obligation to reply without adding content ([Rudin 2025](https://files.eric.ed.gov/fulltext/EJ1478728.pdf)). Reaction-heavy ≠ lurker.

**What the research does NOT support (treat as playful only, or calibrate first-party).**
- **Ball-in-court / "left on read" → personality or attachment style.** No peer-reviewed study measures last-message-position or read-but-no-reply in private messaging and maps it to validated personality/attachment scales. This is the most popular pop-psychology texting idea with the *weakest* empirical backing.
- **Talk/listen word-count ratio → narcissism.** The "narcissists say I more" belief is a debunked myth ([Holtzman et al. 2024](https://onlinelibrary.wiley.com/doi/10.1111/jopy.12936)); I-talk tracks neuroticism/rumination, not narcissism — and only with body text anyway.
- **Slang tokens → age.** Too volatile (12–36 month turnover), too culture/race-confounded, and requires message bodies. Not recommended for automated use.
- **Reply latency → age.** No published benchmark; individual context (job, sleep, relationship) swamps any generational signal.

**Two structural cautions for the whole product:**
1. **Almost all evidence is US/English and WEIRD-sampled.** Several signals (laugh tokens, slang, emoji meaning) are *completely different* for non-English users and need separate calibration or suppression.
2. **No reliable public percentiles exist** for most per-user thresholds (reply latency by age, tapback rate, % messages with emoji, group lurker rate in private chats, read-but-no-reply rate). The product should **benchmark these from first-party local aggregates**, not hardcode invented cutoffs.

The recommended design posture: use the strong signals (volume, concentration, emoji rate, laugh-token type, punctuation, capitalization) as the confident backbone; use the weak-but-fun signals (ball-in-court, left-on-read, reaction style) as *playful observations* with explicit hedging; and never overclaim age or personality as fact.

---

## 2. Signal Inventory Table

Evidence strength legend: **High** = multiple peer-reviewed replications or large representative samples; **Medium** = one solid peer-reviewed study or strong convergent cultural + adjacent evidence; **Low** = anecdotal, qualitative-only, or no direct study in private messaging.

Note on units: signals are separated into **per-user frequency** (counts/day), **per-message rates** (share of messages), and **per-conversation behavior** (who closes a thread). These are not interchangeable.

| Signal | What it measures | Archetype relevance | Age relevance | Evidence strength | Caveats | Recommended product use |
|---|---|---|---|---|---|---|
| **Outbound/inbound volume** (per-user freq) | Total messages sent/received; out:in ratio; msgs per active day | High — extraversion ([Stachl 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/)); volume archetypes | High — strong age decline ([Pew 2011](https://www.pewresearch.org/internet/2011/09/19/how-americans-use-text-messaging/)) | **High** | Conflates initiation vs. response; confounded by occupation; neuroticism can drive volume too | Backbone signal. Use for High-Volume Texter + age band. Benchmark cutoffs first-party |
| **Reply latency** (median/mean, 5/30/60-min %, long-tail) | Time from receipt to first reply; tail behavior | Medium — all Big Five predict notification delay ([Stach 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11053777/)); fast response = honest connection signal ([Templeton 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8794835/)) | Low — no benchmark by age; individual context dominates | **Medium** (personality), **Low** (age) | Read receipts, DND, device context confound; agreeableness paradoxically *slower*; async ≠ the lab studies | Use for Fast/Slow Responder archetypes with hedging. Avoid for age. First-party calibrate |
| **Ball-in-court** (per-conversation) | % active threads where the *other* person sent last | Low — no validated mapping; intuitive only | Low | **Low** | Doesn't distinguish avoidance from busyness; habitual closers; group threads break the metaphor | Playful only ("The Resolver" / "The Initiator"). Never assert personality |
| **"Left on read"** (per-conversation) | Threads where user read but didn't reply | Low — pop-psych concept, no quantified basis | Low | **Low** | Read receipts platform-specific; intent unknowable from metadata | Playful only, gentle copy. First-party calibrate if used at all |
| **Group participation share** (per-conversation) | User's % of messages in each group; lurker vs. MVP | Medium — active=extraversion/openness, lurk=introversion/neuroticism ([Sellen & Buckner 2018](https://bear.buckingham.ac.uk/278/1/Psychology%20of%20Online%20Lurking.pdf)) | Low | **Medium** (public communities), **Low** (private chats) | 90-9-1 is a *public* artifact; private chats softer (~60-30-10); role/topic confounds | Group MVP / Lurker archetypes with non-pejorative framing |
| **Silent groups** (per-conversation) | Groups user is in but never posts to | Medium — "silent presence" is a named phenomenon | Low | **Low** (qualitative) | Not peer-quantified; very relatable though | Playful "Ghost Town" observation |
| **Top-contact concentration** (per-user) | % messages to top 3/5; HHI; unique active contacts | High — breadth↔extraversion ([Pollet 2011](https://tvpollet.github.io/pdfs/Pollet_et_al_2011_JID_paper.pdf)); contact entropy top extraversion predictor ([de Montjoye 2013](http://realitycommons.media.mit.edu/deMontjoye2013predicting-citation.pdf)) | Low | **High** (breadth↔extraversion); **Medium** (depth) | Concentration could mean introvert *or* intimacy-focused extravert; family group = single contact distorts | Concentrated Inner-Circle vs. Social Connector archetypes |
| **Talk/listen ratio** (word count) | User words ÷ partner words per thread | Medium — verbosity↔extraversion; msg length↔openness ([Stachl 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/)) | Low (length); see burst below | **Medium** (with bodies), **Low** (count proxy) | **Needs message bodies**; "I-talk=narcissism" is a myth ([Holtzman 2024](https://onlinelibrary.wiley.com/doi/10.1111/jopy.12936)); accommodation confound | Balanced vs. Monologue archetype. Use msg-count ratio as weak proxy if metadata-only |
| **Inline emoji rate** (per-message) | Share of messages with ≥1 emoji; emoji types | Medium — emoji↔extraversion/agreeableness ([Marko 2022](https://www.frontiersin.org/articles/10.3389/fcomm.2022.840646/full)) | High — strong age decline ([Statista 2023](https://www.facebook.com/Statista.Inc/posts/799207609083277/); [Adobe 2022](https://blog.adobe.com/en/publish/2022/09/13/emoji-trend-report-2022)) | **High** (rate↔age), **Medium** (personality) | No public per-message rate benchmark; ironic vs. literal needs bodies | Emoji-Heavy archetype + age band. First-party calibrate the rate |
| **Emoji type** (😂 vs 💀 vs 👍) | Which emojis dominate | Medium | **Medium** — 😂→Millennial+, 💀→Gen Z, 👍 read as passive-aggressive by Gen Z ([Zhukova & Herring 2024](https://homes.luddy.indiana.edu/herring/zhukova.herring.pdf)) | **Medium** | ~2–3yr shelf life; needs recalibration; high culture risk | Age signal *with* a recalibration mechanism |
| **Tapbacks/reactions** (per-message, separate from inline emoji) | Reaction count ÷ typed messages | Medium — "sequence-closing seconds," a real style ([Rudin 2025](https://files.eric.ed.gov/fulltext/EJ1478728.pdf)) | Low — no age benchmark; norms contested | **Medium** (function), **Low** (prevalence/age) | iMessage tapbacks ≠ other platforms; reaction-only ≠ lurker | Reaction-Only / Acknowledger archetype. Never use for age |
| **Capitalization** (aggregate style) | All-lowercase vs. sentence case vs. ALL CAPS | Low | **Medium** — all-lowercase→Gen Z ([Abirou et al. 2024](https://repository.upenn.edu/bitstreams/edbcaff5-1ee9-41a0-bd39-d02628603290/download)) | **Medium** | Autocap defaults vary; lowercase also = aesthetic/identity, not just age | Age signal, never alone |
| **Punctuation** (period, ellipsis, !, ?) | Terminal punctuation rate; ellipsis use; ! rate | Low — ! ↔ warmth/femininity perception | **Medium** — period-every-sentence & heavy "…" → older; no terminal punct → younger ([Gunraj 2016](https://www.sciencedirect.com/science/article/abs/pii/S0747563215302181)) | **Medium** | Gunraj sample = undergrads only (age diff inferred); norms shifting | Age signal with caveats |
| **Laugh tokens** (lol/haha/lmao/😂/💀) | Which laugh form dominates | Low | **High** (LOL→older), **Medium** (💀→Gen Z) ([Meta 2015](https://research.facebook.com/blog/2015/8/the-not-so-universal-language-of-laughter/)) | **High** (LOL/emoji), **Medium** (skull) | Very high culture risk (jajaja/mdr); needs body or token detection; fast turnover | Strong age signal for English; suppress for non-English |
| **Slang/token counts** | Generational slang frequency | Low | Low–Medium per token but **too noisy** | **Low** | 12–36mo turnover; AAVE/racial confounds; needs bodies | **Avoid** for automated age. First-party only |
| **Burst vs. single long message** | Multi-text streams vs. one paragraph | Low | **Medium** — burst→younger, single formal→older ([Lyngo Lab 2021–22](https://www.lyngolab.com/texting-back-to-back.html)) | **Medium** | Lyngo measures *perception* not behavior; context-dependent | Secondary age signal |
| **Emoji-as-punctuation** | Emoji used mid/end sentence as tone, not standalone | Low | Medium — younger skew | **Low** | Hard to detect without bodies | Optional, body-dependent |
| **Sample size / confidence** | N messages, N threads, N contacts, time span | Critical — gates every output | Critical | **High** (methodological) | — | Mandatory gate on all archetypes (see §4) |

---

## 3. Archetype Recommendations

Each archetype lists primary/secondary signals, threshold *direction* (not invented cutoffs — see §5), confidence, caveats, and copy ideas. Confidence reflects how well the *underlying signal→trait link* is evidenced, not certainty about any individual user.

### 3.1 High-Volume Texter
- **Primary:** outbound volume per active day; unique active contacts.
- **Secondary:** contact entropy/diversity.
- **Threshold direction:** top quantile of outbound/day within the user's own cohort.
- **Confidence:** **High** — volume↔extraversion is the most replicated finding ([Stachl 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/); [de Montjoye 2013](http://realitycommons.media.mit.edu/deMontjoye2013predicting-citation.pdf)).
- **Caveats:** occupation (managers, support roles) and neuroticism-driven checking inflate volume. Frame as behavior, not "you're an extravert."
- **Copy:** "Your thumbs deserve a vacation. You sent more texts than [X]% of people we've seen." Avoid trait claims; describe the behavior.

### 3.2 Concentrated Inner-Circle Texter
- **Primary:** % of messages to top 3–5 contacts (HHI / concentration index).
- **Secondary:** unique active contacts (low), contact entropy (low).
- **Threshold direction:** high concentration = ≥ ~majority of volume to top handful; benchmark against [Dunbar's ~40% to top 5 / ~60% to top 15](https://en.wikipedia.org/wiki/Dunbar%27s_number) as a *reference point only*.
- **Confidence:** **Medium-High** — Dunbar layering is well-replicated, but low concentration↔extraversion is clearer than high concentration↔introversion (could be intimacy-focused extravert) ([Li et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC11896044/)).
- **Caveats:** family group chats counted as one contact distort this; platform fragmentation undercounts breadth.
- **Copy:** "You're a depth-over-breadth texter — your top 3 people get the lion's share." Pair with a "Social Connector" counterpart.

### 3.3 Social Connector / Broad Networker
- **Primary:** high unique active contacts; high contact entropy; low concentration.
- **Confidence:** **High** — contact diversity was the single top extraversion predictor ([de Montjoye 2013](http://realitycommons.media.mit.edu/deMontjoye2013predicting-citation.pdf)).
- **Caveats:** work contacts inflate breadth. Distinguish personal vs. professional if possible.
- **Copy:** "You keep a lot of plates spinning — your messages spread across a wide circle."

### 3.4 Fast Responder
- **Primary:** median reply latency (low); % replied within 5/30 min (high).
- **Secondary:** consistency (low long-tail).
- **Threshold direction:** low median, high within-5-min share. Reference public norms with care: ~50% of notification clicks happen within 30 seconds of appearing, and 64–68% of heavy texters report replying "within a few minutes" ([Sahami et al. 2014](https://pielot.org/pubs/Sahami2014-CHI-NotificationsLarge.pdf); [Pielot 2015](https://pielot.org/2015/05/how-fast-people-expect-responses-to-texts-and-messages/)) — these are *seen/click* norms, not your private async reply latency, so calibrate first-party.
- **Confidence:** **Medium** — fast response is an honest connection signal ([Templeton 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8794835/)); openness/conscientiousness/neuroticism predict faster notification interaction ([Stach 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11053777/)).
- **Caveats:** read receipts, DND/focus modes, and device context heavily confound. Do not equate fast = better.
- **Copy:** "Reply speed of a caffeinated hummingbird. People hear back from you fast." **First-party calibration: High priority.**

### 3.5 Slow-but-Thoughtful Responder
- **Primary:** higher median latency *with* longer average message length (if body length available) or longer typed messages.
- **Secondary:** low burst rate.
- **Confidence:** **Medium-Low** — the "thoughtful" framing is inference; agreeable people respond slower but more carefully ([Stach 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11053777/)). The latency↔deliberation link is plausible, not proven.
- **Caveats:** slowness ≠ thoughtfulness reliably; could be avoidance or busyness.
- **Copy:** "You let texts marinate. When you reply, it's worth the wait." Keep it flattering and hedged.

### 3.6 Conversation Closer (The Resolver)
- **Primary:** high % of threads where *user* sends the last message.
- **Confidence:** **Low** — no validated personality mapping in private messaging; adjacent dominance literature only ([Szymczak 2010](https://rebus.us.edu.pl/bitstream/20.500.12128/2210/1/Szymczak_Verbal_dominance_vs_temperamental_and_anxiety_variables.pdf)).
- **Caveats:** "see you then" is a natural closer, not a trait. Group threads break the metaphor.
- **Copy:** "You like the last word — or at least the last 'sounds good.'" Playful only.

### 3.7 Left-on-Read Person
- **Primary:** high % of threads where the *other* person sent last + read-but-no-reply (read receipts required).
- **Confidence:** **Low** — pop-psych concept, no quantified basis; "left on read" → avoidance is unvalidated.
- **Caveats:** read receipts platform-specific; intent unknowable. Highest risk of feeling judgmental.
- **Copy:** Gentle and self-deprecating: "Some conversations are still… loading. You've got a few open loops." Never imply avoidance or character flaw.

### 3.8 Group Chat Lurker
- **Primary:** low participation share across groups; presence in many silent groups.
- **Confidence:** **Medium** — lurking↔introversion/neuroticism in online communities ([Sellen & Buckner 2018](https://bear.buckingham.ac.uk/278/1/Psychology%20of%20Online%20Lurking.pdf); [Liu et al. 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11327116/)), but private group chats are understudied; the 90-9-1 skew is *softer* in private chats (~60-30-10).
- **Caveats:** lurking can be active, healthy consumption ([Han et al. 2014](https://pmc.ncbi.nlm.nih.gov/articles/PMC4469645/)). **Reframe positively** — never pejorative.
- **Copy:** "Group chat zen master. You read everything, type nothing — and that's a vibe." Consider renaming to "Quiet Observer" or "Deep 1:1 Connector."

### 3.9 Group MVP
- **Primary:** top-quantile participation share; high first-message-in-burst rate (initiator).
- **Secondary:** tagging/plans-making behavior if detectable.
- **Confidence:** **Medium** — maps to Benne & Sheats Initiator-Contributor role; central users are often intrinsically motivated initiators ([Paoletti et al. 2025](https://arxiv.org/abs/2503.13635); [Kim et al. CHI 2020](https://soominkim.github.io/project/CHI20_Kim_Bot_Bunch.pdf)).
- **Caveats:** MVP may be the admin/organizer (conscientiousness + role), not just extraverted. MVP can be topic-dependent, not stable.
- **Copy:** "You're the group's heartbeat — when you go quiet, the chat goes quiet."

### 3.10 Emoji-Heavy Texter
- **Primary:** inline emoji rate (per-message share).
- **Secondary:** emoji-as-punctuation rate (if bodies available).
- **Confidence:** **Medium** — emoji↔extraversion/agreeableness ([Marko 2022](https://www.frontiersin.org/articles/10.3389/fcomm.2022.840646/full)); strong age co-signal.
- **Caveats:** no public per-message emoji rate benchmark — calibrate first-party. Ironic use needs bodies.
- **Copy:** "Your texts come with subtitles. 🎬 You speak fluent emoji."

### 3.11 Reaction-Only Participant
- **Primary:** high tapback/reaction count ÷ typed message count.
- **Confidence:** **Medium** — a real, recognized style (sequence-closing seconds), distinct from lurking ([Rudin 2025](https://files.eric.ed.gov/fulltext/EJ1478728.pdf)); reactions replace follow-up messages ([Slack data](https://slack.com/blog/collaboration/emoji-use-at-work)).
- **Caveats:** tapbacks are iMessage-specific; cross-platform reactions differ. Norms are contested ([Mashable 2019](https://mashable.com/article/what-do-imessage-reactions-tapbacks-mean)).
- **Copy:** "Why type when a ❤️ says it all? You're an efficiency icon." Frame as a skill, not laziness.

### 3.12 Balanced Talk/Listener
- **Primary:** talk/listen word-count ratio near parity (bodies) or message-count ratio near 1:1 (metadata proxy).
- **Confidence:** **Medium** (with bodies), **Low** (count proxy).
- **Caveats:** count ratio ≠ word ratio; accommodation confound.
- **Copy:** "Perfectly balanced, as conversations should be. You give and take in equal measure."

### 3.13 Monologue Texter
- **Primary:** high talk share (word count) + burst/multi-text streams.
- **Confidence:** **Medium** — verbosity↔extraversion, length↔openness ([Stachl 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/)). **Do NOT** invoke narcissism — that link is debunked ([Holtzman 2024](https://onlinelibrary.wiley.com/doi/10.1111/jopy.12936)).
- **Caveats:** needs bodies for word count; could be a storyteller, not self-centered.
- **Copy:** "You don't text, you broadcast. Your friends get the director's cut." Affectionate, never "narcissist."

**Archetype design principles:** (1) every archetype is a behavior description with a wink, not a diagnosis; (2) low-confidence archetypes get softer, more self-deprecating copy; (3) pair "negative-sounding" archetypes with a positive reframe; (4) gate display on sample size (§4).

---

## 4. Texting-Age Recommendations

### Signals to use (in priority order)
1. **Daily message volume** — strongest numeric age signal; ~23× difference between 18–24 and 65+ ([Pew 2011](https://www.pewresearch.org/internet/2011/09/19/how-americans-use-text-messaging/)). **High.**
2. **Inline emoji rate** — monotonic decline with age ([Statista 2023](https://www.facebook.com/Statista.Inc/posts/799207609083277/)). **High.**
3. **Laugh-token type** — "LOL" skews oldest of all laugh forms; emoji-laugh skews youngest; 💀 strong Gen Z ([Meta 2015](https://research.facebook.com/blog/2015/8/the-not-so-universal-language-of-laughter/)). **High (LOL/emoji), Medium (skull).** English only.
4. **Terminal punctuation + ellipsis** — period-every-sentence and heavy "…" → older; no terminal punctuation → younger ([Gunraj 2016](https://www.sciencedirect.com/science/article/abs/pii/S0747563215302181)). **Medium.**
5. **Capitalization** — consistent all-lowercase → Gen Z ([Abirou 2024](https://repository.upenn.edu/bitstreams/edbcaff5-1ee9-41a0-bd39-d02628603290/download)). **Medium.**
6. **Emoji type** (😂 vs 💀) — directional, with recalibration. **Medium.**
7. **Burst vs. single long message** — burst → younger ([Lyngo Lab](https://www.lyngolab.com/texting-back-to-back.html)). **Medium.**

**Composite recommendation:** the most robust texting-age estimate combines *emoji rate + laugh-token type + terminal-period rate + all-lowercase rate + daily volume*. No single signal should drive the age read.

### Signals to avoid or heavily downweight for age
- **Slang tokens** — too volatile and culture/race-confounded. **Avoid.**
- **Reply latency** — no age benchmark; individual context dominates. **Avoid for age.**
- **Tapbacks/reactions** — no population benchmark; iMessage-only; contested norms. **Avoid for age.**
- **Ironic vs. literal emoji** — needs bodies; indistinguishable from metadata. **Avoid.**

### How to weight confidence
- Treat texting age as a **probability distribution over generation bands**, not a point estimate.
- Weight signals by evidence strength: volume and emoji rate carry the most weight; capitalization/punctuation are tie-breakers; emoji-type and burst are light nudges.
- **Suppress non-English calibration:** if the user's dominant language isn't English, disable laugh-token, slang, and emoji-meaning signals and fall back to volume + emoji rate only (with a wider confidence band), or skip age entirely.
- Apply a **decay/recalibration flag** on emoji-type and laugh-token mappings (2–3 year shelf life).

### Sample-size rules (gate before showing any age read)
- **Minimum ~500 outbound messages** across **≥ 30 active days** before showing a texting age at all (below this, show "still learning your style").
- Require **≥ 3 of the 7 usable signals** to agree directionally before narrowing the band.
- Always present age as **playful and probabilistic**: "Your texting energy reads early-Millennial," never "You are 34."
- Widen the band when signals conflict; show the *band*, not false precision.

---

## 5. Threshold Calibration Guidance

The core principle: **search results and surveys give you reference *shapes and directions*, not per-user cutoffs.** Hardcoding public numbers as personal thresholds will misfire. Calibrate distribution-relative cutoffs from first-party local aggregates.

### Can be benchmarked from public research (use as reference anchors, not hard cutoffs)
| Metric | Public anchor | Source | Use |
|---|---|---|---|
| Daily text volume by age | All adults median 10/day; 18–24 median 50/day; teens 60–100/day | [Pew 2011/2012](https://www.pewresearch.org/internet/2011/09/19/how-americans-use-text-messaging/) | Age-band priors; **US, 2011 — stale, directional only** |
| Notification view/click time | Median view 3.5–6.6 min; 50% click within 30s; 83% within 5 min | [Pielot 2014](https://www.ic.unicamp.br/~oliveira/doc/MHCI2014_An-in-situ-study-of-mobile-phone-notifications.pdf); [Sahami 2014](https://pielot.org/pubs/Sahami2014-CHI-NotificationsLarge.pdf) | "Fast" reference — but it's *seen-time*, not async reply |
| Response expectation norms | 64–68% expect/give replies "within a few minutes" | [Pielot 2015](https://pielot.org/2015/05/how-fast-people-expect-responses-to-texts-and-messages/) | Latency framing; N=44, European |
| Contact concentration | ~40% of social effort to top 5, ~60% to top 15 | [Dunbar FT 2018](https://en.wikipedia.org/wiki/Dunbar%27s_number); [MacCarron 2016](https://arxiv.org/abs/1604.02400) | Inner-circle archetype anchor |
| Punctuation base rates | 39% of sentences have final punctuation; 29% of messages end with punctuation; <5% abbreviated words | [Ling & Baron 2007](https://nl.ijs.si/janes/wp-content/uploads/2014/09/lingbaron07.pdf) | "Period user" baseline; US, 2005, female students — old |
| Laugh-token frequency | "lol" ~0.4–0.7%, "haha" ~0.4–1.5% of all words | [Tagliamonte & Denis 2008](https://doi.org/10.1215/00031283-2008-001) | Laugh-density sanity check; Canadian teen IM |
| Group size distribution | 71.5% of WhatsApp groups are dyadic; <1% > 50 members | [Rosenfeld et al. 2018](https://www.demographic-research.org/volumes/vol39/22/39-22.pdf) | Group-size context; **Israel** |
| Emoji ranking | Top US emoji: 😂, 👍, ❤️, 🤣, 😢 | [Unicode 2019](https://home.unicode.org/emoji/emoji-frequency/); [Adobe 2022](https://blog.adobe.com/en/publish/2022/09/13/emoji-trend-report-2022) | Emoji-type interpretation |

### Must be first-party calibrated (no reliable public benchmark exists — do NOT invent)
- **Reply latency percentiles in private async messaging** (by age and overall).
- **% of messages containing ≥1 emoji** (no rigorous corpus; the floating "72%" is unsourced aggregator content).
- **Tapback/reaction rate** (per message, by age, by platform).
- **Read-but-no-reply rate** in personal messaging (only qualitative work exists — [Chou et al. CHI 2022](https://dl.acm.org/doi/10.1145/3491102.3517496)).
- **Group-chat lurker/participation distribution in private friendship/family chats** (public-community rates don't transfer).
- **Post-2015 age-stratified daily volume** (no Pew-equivalent exists; Pew 2011 is the latest rigorous granular data).
- **Burst/multi-text frequency by age** (Lyngo measured perception, not behavior).

### Recommended calibration mechanism
1. Compute **per-user distributions locally** (on-device), then derive archetype thresholds as **within-population quantiles** (e.g., top 20% of *this user base's* volume), not absolute numbers.
2. Maintain **cohort-relative baselines** so "fast" or "high-volume" means relative to comparable users, not a stale 2011 survey.
3. Ship a **recalibration cadence** (every ~2–3 years, or telemetry-triggered) for emoji-type and laugh-token age mappings.
4. When N is below the sample-size gate, **widen bands and hedge copy** rather than guessing.

---

## 6. Privacy-Safe Telemetry Plan

**Hard constraint:** never store or upload message bodies, contact identities, or anything reconstructable into message content. Everything below is **aggregate, derived, and non-reversible.** All raw computation happens on-device; only coarse aggregates (optionally, with explicit consent) are collected to calibrate thresholds across the population.

### Tier 1 — On-device only (never leaves device)
Used to compute the user's own archetypes/age locally:
- Per-thread timestamps (for latency/burst computation) — discarded after aggregation.
- Per-contact message counts and direction.
- Per-group message counts and the user's share.
- Inline emoji counts, tapback/reaction counts, laugh-token counts, punctuation/capitalization tallies — **counts only, never the text.**

### Tier 2 — Optional consented aggregates (for population calibration)
Each field is a coarse-bucketed number or distribution, with k-anonymity thresholds and no contact identifiers. Collect only with explicit opt-in.

| Field | Type | Notes |
|---|---|---|
| `reply_latency_median_bucket` | bucketed minutes (e.g., <1, 1–5, 5–30, 30–60, >60) | Per-user, not per-thread |
| `reply_within_5min_pct`, `within_30min_pct`, `within_60min_pct` | rounded % | Coarse to 5–10% buckets |
| `reply_latency_p90_bucket` | bucketed | Long-tail behavior |
| `outbound_per_active_day_bucket` | bucketed count | Volume calibration |
| `inbound_outbound_ratio_bucket` | bucketed ratio | Talk/listen proxy |
| `unique_active_contacts_bucket` | bucketed count | Breadth |
| `top3_contact_concentration_pct` | rounded % | Concentration (no contact IDs) |
| `ball_in_court_other_pct` | rounded % | Per-conversation aggregate |
| `read_no_reply_pct` | rounded % | Only if read receipts available |
| `group_count_bucket`, `silent_group_count_bucket` | bucketed | Group participation |
| `median_group_share_pct` | rounded % | Lurker/MVP calibration |
| `inline_emoji_rate_per_msg_bucket` | bucketed % | Emoji rate (NOT which emoji content) |
| `tapback_to_typed_ratio_bucket` | bucketed | Reaction-only calibration |
| `top_emoji_category` | small enum (laugh/heart/positive/negative/hand/other) | Coarse category, never raw emoji strings tied to content |
| `dominant_laugh_token` | enum (lol/haha/lmao/emoji-laugh/skull/none) | Token *type* only |
| `terminal_punctuation_rate_bucket` | bucketed % | Age calibration |
| `ellipsis_rate_bucket`, `exclamation_rate_bucket` | bucketed % | Age calibration |
| `all_lowercase_rate_bucket` | bucketed % | Age calibration |
| `burst_message_rate_bucket` | bucketed % | Burst-style age signal |
| `dominant_language` | enum | Gates non-English suppression |
| `sample_size_band` | enum (insufficient/low/medium/high) | Confidence gating |
| `platform_mix` | enum shares (iMessage/SMS/WhatsApp/other) | Platform-specificity flags |
| `self_reported_age_band` | optional enum, opt-in | **The key first-party label** for validating age signals |
| `archetype_feedback` | enum (accurate/funny/wrong) | Validates archetype mappings |

### Privacy guardrails
- **Bucket everything**; never transmit raw counts or timestamps.
- **k-anonymity gate** on any reported aggregate (suppress small cells).
- **No contact identifiers, no emoji strings tied to message content, no message text — ever.**
- **Opt-in for Tier 2**; Tier 1 stays fully local.
- Optional self-reported age band + archetype feedback are the highest-value labels for closing the calibration gaps — collect them gently and optionally.

---

## 7. Source List with Links and Confidence Notes

### Personality / social-style signals
- **Stachl et al. 2020, PNAS** — phone behavior → Big Five; extraversion most predictable; message length → openness. ★★★★★ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC7395458/)
- **de Montjoye et al. 2013, MIT** — contact entropy top extraversion predictor; 61% accuracy. ★★★☆☆ (small/old dataset) [link](http://realitycommons.media.mit.edu/deMontjoye2013predicting-citation.pdf)
- **Stach et al. 2024, Sensors** — Big Five → notification interaction delay (N=922, ~10M notifications). ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC11053777/)
- **Templeton et al. 2022, PNAS** — fast response time = honest social-connection signal (lab, verbal). ★★★★★ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC8794835/)
- **Pollet, Roberts & Dunbar 2011** — extraversion ↔ larger network at every layer (r≈.20–.23). ★★★★☆ [link](https://tvpollet.github.io/pdfs/Pollet_et_al_2011_JID_paper.pdf)
- **MacCarron, Kaski & Dunbar 2016, Social Networks** — Dunbar layers in 6B-call dataset. ★★★★☆ [link](https://arxiv.org/abs/1604.02400)
- **Li et al. 2025, PLOS ONE** — extraversion NOT linked to energy allocation across layers (breadth ≠ depth). ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC11896044/)
- **Holtzman et al. 2024, J Personality** — "narcissists say I more" is a myth; I-talk ↔ neuroticism/rumination. ★★★★★ [link](https://onlinelibrary.wiley.com/doi/10.1111/jopy.12936)
- **Pennebaker & King 1999, JPSP** — foundational LIWC personality work (essays). ★★★★★ [link](https://pubmed.ncbi.nlm.nih.gov/10626371/)
- **Schwartz et al. 2013, PLOS ONE** — open-vocabulary personality from 75k Facebook users (public posts, not private msgs). ★★★★★ [link](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0073791)
- **Spitzley et al. 2022, Front Psychol** — language↔personality weaker in interactive vs. solitary writing. ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC9523152/)
- **Marengo et al. 2020, J Behav Addict** — meta-analysis: neuroticism ↔ smartphone use (r=.25). ★★★★★ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC8943667/)
- **Marko 2022, Front Communication** — emoji frequency ↔ extraversion/agreeableness. ★★★☆☆ [link](https://www.frontiersin.org/articles/10.3389/fcomm.2022.840646/full)
- **Szymczak 2010** — verbal dominance ↔ extraversion/neuroticism (adjacent, task-based). ★★★☆☆ [link](https://rebus.us.edu.pl/bitstream/20.500.12128/2210/1/Szymczak_Verbal_dominance_vs_temperamental_and_anxiety_variables.pdf)
- **Halpern & Katz 2017, Comput Human Behav** — one-sided initiation ↔ anxious attachment, lower relationship quality. ★★★★☆ [link](https://www.sciencedirect.com/science/article/abs/pii/S0747563217300651)
- **Doorley et al. 2020, J Affect Disord** — social anxiety does NOT increase texting preference (null). ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC7484355/)

### Age / generation signals
- **Pew Research 2011/2012** — age-stratified text volume (US, rigorous, but stale). ★★★★★ [link](https://www.pewresearch.org/internet/2011/09/19/how-americans-use-text-messaging/)
- **Statista 2023** — emoji frequency declines with age (US). ★★★★☆ [link](https://www.facebook.com/Statista.Inc/posts/799207609083277/)
- **Adobe 2022 US Emoji Trend Report** — generational emoji use/interpretation (frequent-user sample, not representative). ★★★☆☆ [link](https://blog.adobe.com/en/publish/2022/09/13/emoji-trend-report-2022)
- **Meta Research 2015** — laugh tokens by age: LOL oldest, emoji-laugh youngest. ★★★★☆ [link](https://research.facebook.com/blog/2015/8/the-not-so-universal-language-of-laughter/)
- **Gunraj et al. 2016, Comput Human Behav** — period at end of text → less sincere (undergrad sample). ★★★★☆ [link](https://www.sciencedirect.com/science/article/abs/pii/S0747563215302181)
- **Zhukova & Herring 2024, Indiana U** — generational emoji interpretation (👍/😊 read passive-aggressive by Gen Z). ★★★★☆ [link](https://homes.luddy.indiana.edu/herring/zhukova.herring.pdf)
- **Abirou et al. 2024, UPenn** — all-lowercase perceived as younger/trendier (preprint). ★★★☆☆ [link](https://repository.upenn.edu/bitstreams/edbcaff5-1ee9-41a0-bd39-d02628603290/download)
- **Lyngo Lab 2021–22** — burst vs. paragraph likability skews younger (perception study). ★★★☆☆ [link](https://www.lyngolab.com/texting-back-to-back.html)
- **Wu et al. 2024, Front Psychol** — emoji age effects on WeChat (China — not US-generalizable). ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC11333970/)
- **McCulloch 2019, *Because Internet*** — linguistic framing of internet-era cohorts. ★★★★☆ (book) [link](https://gretchenmcculloch.com/book/)

### Public benchmarks / corpora
- **Pielot et al. 2014, MobileHCI** — notification view times (N=15). ★★★☆☆ [link](https://www.ic.unicamp.br/~oliveira/doc/MHCI2014_An-in-situ-study-of-mobile-phone-notifications.pdf)
- **Sahami Shirazi et al. 2014, CHI** — large-scale notification clicks (N=40,191). ★★★★★ [link](https://pielot.org/pubs/Sahami2014-CHI-NotificationsLarge.pdf)
- **Ling & Baron 2007, JLSP** — SMS punctuation/abbreviation base rates (US, 2005, small). ★★★☆☆ [link](https://nl.ijs.si/janes/wp-content/uploads/2014/09/lingbaron07.pdf)
- **Tagliamonte & Denis 2008, American Speech** — laugh-token & CMC-form frequency (Canadian teen IM). ★★★★☆ [link](https://doi.org/10.1215/00031283-2008-001)
- **Rosenfeld et al. 2018, Demographic Research** — WhatsApp group size distribution (Israel). ★★★★☆ [link](https://www.demographic-research.org/volumes/vol39/22/39-22.pdf)
- **Unicode Consortium 2019** — emoji frequency ranking. ★★★★☆ [link](https://home.unicode.org/emoji/emoji-frequency/)
- **NUS SMS Corpus** — 67k SMS, Singapore (dataset, non-US). ★★★☆☆ [link](https://github.com/WING-NUS/nus-sms-corpus)

### Group participation & reactions
- **Nielsen 2006, NN/g** — 90-9-1 participation inequality (public communities). ★★★★★ [link](https://www.nngroup.com/articles/participation-inequality/)
- **Rudin 2025, Teachers College Columbia** — iMessage tapbacks as sequence-closing seconds. ★★★★☆ (small qualitative) [link](https://files.eric.ed.gov/fulltext/EJ1478728.pdf)
- **Liu et al. 2024, Front Psychol** — lurking driven by fatigue/anxiety (WeChat, N=836). ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC11327116/)
- **Han et al. 2014, Health Communication** — lurking as active, healthy participation. ★★★★☆ [link](https://pmc.ncbi.nlm.nih.gov/articles/PMC4469645/)
- **Sellen & Buckner 2018, Oxford Handbook of Lurking** — personality ↔ lurking synthesis. ★★★★☆ [link](https://bear.buckingham.ac.uk/278/1/Psychology%20of%20Online%20Lurking.pdf)
- **Kim et al. 2020, CHI (GroupfeedBot)** — contribution inequality in group chats; message/word count metrics. ★★★★☆ [link](https://soominkim.github.io/project/CHI20_Kim_Bot_Bunch.pdf)
- **Paoletti et al. 2025, arXiv** — initiators are central, intrinsically motivated (Telegram, public). ★★★☆☆ [link](https://arxiv.org/abs/2503.13635)
- **Chou et al. 2022, CHI** — read-but-no-reply typology (qualitative, no base rate). ★★★★☆ [link](https://dl.acm.org/doi/10.1145/3491102.3517496)
- **Slack 2022 / Duolingo survey** — reactions replace follow-up messages (workplace). ★★★☆☆ [link](https://slack.com/blog/collaboration/emoji-use-at-work)
- **Mashable 2019** — no consensus on tapback meaning. ★★☆☆☆ (journalism) [link](https://mashable.com/article/what-do-imessage-reactions-tapbacks-mean)

### Confidence note
Star ratings reflect study rigor and directness to private messaging. Most evidence is **US/English and WEIRD-sampled**; non-US/non-English generalization is uncertain throughout. Several flagship sources (Pew volume, Ling & Baron punctuation) are 10–15 years old and should be treated as **directional, not current.** No population percentile in this report should be presented to users as a personal threshold — see §5.

---

## 8. Machine-Readable Summary (JSON)

```json
{
  "signals": [
    {"id": "outbound_inbound_volume", "evidence_strength": "high", "archetype_use": "recommended", "age_use": "recommended", "needs_first_party_calibration": true},
    {"id": "reply_latency_median", "evidence_strength": "medium", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "reply_latency_within_thresholds", "evidence_strength": "medium", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "reply_latency_long_tail", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "ball_in_court", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "left_on_read", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "group_participation_share", "evidence_strength": "medium", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "silent_groups", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "top_contact_concentration", "evidence_strength": "high", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "contact_entropy_breadth", "evidence_strength": "high", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "talk_listen_word_ratio", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "talk_listen_count_proxy", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "inline_emoji_rate", "evidence_strength": "high", "archetype_use": "recommended", "age_use": "recommended", "needs_first_party_calibration": true},
    {"id": "emoji_type", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "cautious", "needs_first_party_calibration": true},
    {"id": "tapbacks_reactions", "evidence_strength": "medium", "archetype_use": "recommended", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "capitalization_style", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "recommended", "needs_first_party_calibration": true},
    {"id": "terminal_punctuation_rate", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "recommended", "needs_first_party_calibration": true},
    {"id": "ellipsis_rate", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "cautious", "needs_first_party_calibration": true},
    {"id": "exclamation_rate", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "cautious", "needs_first_party_calibration": true},
    {"id": "laugh_tokens", "evidence_strength": "high", "archetype_use": "cautious", "age_use": "recommended", "needs_first_party_calibration": true},
    {"id": "slang_tokens", "evidence_strength": "low", "archetype_use": "avoid", "age_use": "avoid", "needs_first_party_calibration": true},
    {"id": "burst_vs_single_message", "evidence_strength": "medium", "archetype_use": "cautious", "age_use": "cautious", "needs_first_party_calibration": true},
    {"id": "emoji_as_punctuation", "evidence_strength": "low", "archetype_use": "cautious", "age_use": "cautious", "needs_first_party_calibration": true},
    {"id": "sample_size_confidence", "evidence_strength": "high", "archetype_use": "recommended", "age_use": "recommended", "needs_first_party_calibration": false}
  ],
  "archetypes": [
    {"id": "high_volume_texter", "recommended": true, "primary_signals": ["outbound_inbound_volume", "contact_entropy_breadth"], "secondary_signals": ["inline_emoji_rate"], "confidence": "high", "needs_first_party_calibration": true},
    {"id": "concentrated_inner_circle", "recommended": true, "primary_signals": ["top_contact_concentration"], "secondary_signals": ["contact_entropy_breadth"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "social_connector", "recommended": true, "primary_signals": ["contact_entropy_breadth", "top_contact_concentration"], "secondary_signals": ["outbound_inbound_volume"], "confidence": "high", "needs_first_party_calibration": true},
    {"id": "fast_responder", "recommended": true, "primary_signals": ["reply_latency_median", "reply_latency_within_thresholds"], "secondary_signals": ["reply_latency_long_tail"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "slow_thoughtful_responder", "recommended": true, "primary_signals": ["reply_latency_median"], "secondary_signals": ["talk_listen_word_ratio", "burst_vs_single_message"], "confidence": "low", "needs_first_party_calibration": true},
    {"id": "conversation_closer", "recommended": false, "primary_signals": ["ball_in_court"], "secondary_signals": [], "confidence": "low", "needs_first_party_calibration": true},
    {"id": "left_on_read_person", "recommended": false, "primary_signals": ["left_on_read", "ball_in_court"], "secondary_signals": [], "confidence": "low", "needs_first_party_calibration": true},
    {"id": "group_chat_lurker", "recommended": true, "primary_signals": ["group_participation_share", "silent_groups"], "secondary_signals": [], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "group_mvp", "recommended": true, "primary_signals": ["group_participation_share"], "secondary_signals": ["ball_in_court"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "emoji_heavy_texter", "recommended": true, "primary_signals": ["inline_emoji_rate"], "secondary_signals": ["emoji_as_punctuation", "emoji_type"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "reaction_only_participant", "recommended": true, "primary_signals": ["tapbacks_reactions"], "secondary_signals": ["group_participation_share"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "balanced_talk_listener", "recommended": true, "primary_signals": ["talk_listen_word_ratio"], "secondary_signals": ["talk_listen_count_proxy"], "confidence": "medium", "needs_first_party_calibration": true},
    {"id": "monologue_texter", "recommended": true, "primary_signals": ["talk_listen_word_ratio", "burst_vs_single_message"], "secondary_signals": [], "confidence": "medium", "needs_first_party_calibration": true}
  ],
  "age_model": {
    "recommended_signals": ["outbound_inbound_volume", "inline_emoji_rate", "laugh_tokens", "terminal_punctuation_rate", "capitalization_style", "emoji_type", "burst_vs_single_message"],
    "avoid_or_downweight": ["slang_tokens", "reply_latency_median", "tapbacks_reactions", "emoji_as_punctuation"],
    "minimum_sample_size": 500,
    "confidence_policy": "Output a probability distribution over generation bands, never a point age. Require >=3 of 7 usable signals to agree before narrowing the band. Weight by evidence strength (volume + emoji rate highest). Suppress laugh-token/slang/emoji-meaning signals for non-English users and widen the band. Apply a 2-3 year recalibration flag to emoji-type and laugh-token mappings. Below 500 outbound messages or 30 active days, show 'still learning' instead of an age."
  },
  "first_party_calibration_fields": [
    "reply_latency_median_bucket",
    "reply_within_5min_pct",
    "reply_within_30min_pct",
    "reply_within_60min_pct",
    "reply_latency_p90_bucket",
    "outbound_per_active_day_bucket",
    "inbound_outbound_ratio_bucket",
    "unique_active_contacts_bucket",
    "top3_contact_concentration_pct",
    "ball_in_court_other_pct",
    "read_no_reply_pct",
    "group_count_bucket",
    "silent_group_count_bucket",
    "median_group_share_pct",
    "inline_emoji_rate_per_msg_bucket",
    "tapback_to_typed_ratio_bucket",
    "top_emoji_category",
    "dominant_laugh_token",
    "terminal_punctuation_rate_bucket",
    "ellipsis_rate_bucket",
    "exclamation_rate_bucket",
    "all_lowercase_rate_bucket",
    "burst_message_rate_bucket",
    "dominant_language",
    "sample_size_band",
    "platform_mix",
    "self_reported_age_band",
    "archetype_feedback"
  ],
  "highest_priority_research_gaps": [
    "Reply latency percentiles in private async messaging, overall and by age (no public benchmark)",
    "Read-but-no-reply rate in personal messaging (only qualitative work exists)",
    "Ball-in-court / last-message-position mapped to validated personality or attachment scales",
    "Tapback/reaction rate by age and platform (no population data)",
    "Group-chat participation distribution in private friendship/family chats (public 90-9-1 does not transfer)",
    "Per-message emoji rate by age in private messaging (no rigorous corpus)",
    "Post-2015 age-stratified daily text volume (no Pew-equivalent since 2012)",
    "Cross-cultural / non-English calibration for laugh tokens, slang, emoji meaning, punctuation"
  ]
}
```

---

*Compiled for BetterHuman / Texting Wrapped, 2026-06-09. All signals are aggregate or stylistic; no message bodies required or stored. Evidence strength is separated from speculation throughout; population percentiles are never invented — where no benchmark exists, first-party calibration is recommended.*
