// ────────────────────────────────────────────────────────────
// Texting Wrapped — card components + carousel
// ────────────────────────────────────────────────────────────
// From a Claude Design handoff (claude.ai/design). The original prototype
// hard-coded a DATA object; this version reads window.WRAPPED_DATA so the
// texting-analytics skill can inject a real analysis.json via build_wrapped.py.
// When window.WRAPPED_DATA is absent (opening index.html directly), it falls
// back to the design's sample data so the prototype still renders standalone.

const { useState, useEffect, useRef, useMemo, useCallback } = React;

function notifyNative(action) {
  try {
    window.webkit?.messageHandlers?.messagesForAIWrapped?.postMessage({ action });
  } catch (_) {}
}

const nativeWrappedFileRequests = new Map();
if (typeof window !== 'undefined') {
  window.__messagesForAIWrappedNativeResult = (result) => {
    const requestId = result && result.requestId;
    if (!requestId || !nativeWrappedFileRequests.has(requestId)) return;
    nativeWrappedFileRequests.get(requestId)({
      ok: !!result.ok,
      error: result && result.error ? String(result.error) : null,
    });
    nativeWrappedFileRequests.delete(requestId);
  };
}

function hasNativeWrappedFileBridge() {
  return !!(typeof window !== 'undefined'
    && window.webkit
    && window.webkit.messageHandlers
    && window.webkit.messageHandlers.messagesForAIWrapped);
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const value = String(reader.result || '');
      resolve(value.includes(',') ? value.split(',').pop() : value);
    };
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

function blobToDrawable(blob) {
  if (typeof createImageBitmap === 'function') {
    return createImageBitmap(blob);
  }
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(blob);
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = (error) => {
      URL.revokeObjectURL(url);
      reject(error);
    };
    img.src = url;
  });
}

async function sendNativeWrappedFile({ action, filename, blob }) {
  if (!hasNativeWrappedFileBridge()) return { ok: false, error: 'missing_native_bridge' };
  const requestId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const base64 = await blobToBase64(blob);
  return await new Promise((resolve) => {
    const timeout = setTimeout(() => {
      nativeWrappedFileRequests.delete(requestId);
      resolve({ ok: false, error: 'native_timeout' });
    }, 12000);
    nativeWrappedFileRequests.set(requestId, (ok) => {
      clearTimeout(timeout);
      resolve(ok);
    });
    try {
      window.webkit.messageHandlers.messagesForAIWrapped.postMessage({
        action,
        requestId,
        filename,
        mimeType: blob.type || 'image/png',
        base64,
      });
    } catch (_) {
      clearTimeout(timeout);
      nativeWrappedFileRequests.delete(requestId);
      resolve({ ok: false, error: 'native_post_failed' });
    }
  });
}

// ── Data ────────────────────────────────────────────────────
// Injected by build_wrapped.py as window.WRAPPED_DATASETS — an object with a
// `past_year` and (optionally) an `all_time` card-data payload. The in-page
// window toggle switches between them (default: past year). Older single-
// payload window.WRAPPED_DATA still works; opening index.html directly with
// neither falls back to the design's sample data so the prototype renders.
const DATASETS = (typeof window !== 'undefined' && window.WRAPPED_DATASETS) || null;

const SAMPLE_DATA = {
  year: 2026,
  totalSent: 12400,
  topPeople: [
    { name: 'Maya Chen',     count: 2847, tag: 'best friend' },
    { name: 'Daniel Park',   count: 1962, tag: 'partner' },
    { name: 'Jordan Reyes',  count: 1403, tag: 'sibling' },
    { name: 'Sophie Liu',    count: 982,  tag: 'co-founder' },
    { name: 'Alex Whitman',  count: 711,  tag: 'mom' },
  ],
  median: 8.6,           // min
  mean: 85.5,            // min
  fastPct: 47,           // % within 5 min
  ballInCourt: 93,       // % active threads waiting on you
  groupContribPct: 0.7,
  silentGroups: 12,
  totalGroups: 15,
  worstGhost: { messages: 1589, name: 'kayak crew 🚣' },
  archetype: {
    name: 'The Group Chat Ghost',
    verdict: 'present in name, absent in spirit.',
    why: '0.7% group share, silent in 12 of 15 groups.',
  },
  // cards: ordered list of card keys to render. Absent → full arc.
};

// Active dataset state. Module-level (mutable) because the card components
// read DATA directly; the App remounts the carousel (key={windowKey}) when the
// window toggles, so every card re-reads the new dataset.
const WINDOW_KEYS = ['past_year', 'all_time'];
function datasetFor(key) { return DATASETS && DATASETS[key] ? DATASETS[key] : null; }
const INITIAL_WINDOW = datasetFor('past_year') ? 'past_year' : (datasetFor('all_time') ? 'all_time' : 'past_year');
let DATA = datasetFor(INITIAL_WINDOW)
  || (typeof window !== 'undefined' && window.WRAPPED_DATA)
  || SAMPLE_DATA;

// Full card arc — used to keep each card's designed palette even when some
// cards are omitted (build_wrapped drops cards the analysis can't populate).
const FULL_ARC = ['cover', 'volume', 'people', 'people_l30', 'talk_listen', 'latency', 'ballincourt', 'groups', 'emoji', 'age', 'archetype', 'share'];

// ── Hooks ───────────────────────────────────────────────────

// Count-up animation, eased
function useCountUp(target, durationMs = 1100, active = true, startDelay = 200, instant = false) {
  const [val, setVal] = useState(active ? 0 : target);
  const wasActive = useRef(active);
  useEffect(() => {
    if (instant) { setVal(target); return; }  // capture mode: jump to final value
    if (!active) {
      // Reset only if we were previously active
      if (wasActive.current) setVal(0);
      wasActive.current = false;
      return;
    }
    wasActive.current = true;
    let raf = 0;
    let startedAt = null;
    let cancelled = false;
    const tick = (t) => {
      if (cancelled) return;
      if (startedAt === null) startedAt = t;
      const k = Math.min(1, (t - startedAt) / durationMs);
      const eased = 1 - Math.pow(1 - k, 3);
      setVal(target * eased);
      if (k < 1) raf = requestAnimationFrame(tick);
    };
    const delayTimer = setTimeout(() => {
      raf = requestAnimationFrame(tick);
    }, startDelay);
    return () => {
      cancelled = true;
      clearTimeout(delayTimer);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [target, durationMs, active, startDelay, instant]);
  return val;
}

function fmt(n, decimals = 0) {
  if (decimals > 0) return n.toFixed(decimals);
  return Math.round(n).toLocaleString('en-US');
}

// short archetype tag for the recap tile (last word, or explicit .short)
function archetypeShort() {
  if (DATA.archetype && DATA.archetype.short) return DATA.archetype.short;
  const name = (DATA.archetype && DATA.archetype.name) || '';
  const parts = name.replace(/^The\s+/i, '').split(' ');
  return parts[parts.length - 1] || '—';
}

// ── Card shell ──────────────────────────────────────────────

function CardShell({ tone, treatment, label, children, footer, onTap }) {
  const titleFamily =
    treatment.titleFont === 'serif' ? treatment.serif :
    treatment.titleFont === 'mono'  ? treatment.mono  : treatment.sans;
  const bodyFamily =
    treatment.bodyFont === 'serif' ? treatment.serif :
    treatment.bodyFont === 'mono'  ? treatment.mono  : treatment.sans;
  return (
    <div
      onClick={onTap}
      style={{
        position: 'absolute', inset: 0,
        background: tone.bg,
        color: tone.ink,
        padding: '78px 30px 62px',
        display: 'flex', flexDirection: 'column',
        fontFamily: bodyFamily,
        overflow: 'hidden',
      }}>
      {/* Grain texture overlay */}
      {treatment.grain > 0 && (
        <div style={{
          position: 'absolute', inset: 0, pointerEvents: 'none',
          opacity: treatment.grain,
          backgroundImage: 'url("data:image/svg+xml;utf8,<svg xmlns=\\"http://www.w3.org/2000/svg\\" width=\\"160\\" height=\\"160\\"><filter id=\\"n\\"><feTurbulence type=\\"fractalNoise\\" baseFrequency=\\"0.9\\" numOctaves=\\"2\\" seed=\\"3\\"/><feColorMatrix values=\\"0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0\\"/></filter><rect width=\\"160\\" height=\\"160\\" filter=\\"url(%23n)\\"/></svg>")',
          mixBlendMode: 'overlay',
        }}/>
      )}

      {/* Masthead wordmark — appears at the top of every captured share image
          so the shared PNG has subtle attribution even out of context. */}
      <div style={{
        fontFamily: treatment.mono, fontSize: 10, letterSpacing: '0.18em',
        textTransform: 'uppercase', color: tone.soft, fontWeight: 500,
        opacity: 0.55, marginBottom: 10,
      }}>texting wrapped · textingwrapped.com</div>

      {/* Top label */}
      {label && (
        <div style={{
          fontFamily: treatment.mono, fontSize: 13, letterSpacing: '0.12em',
          textTransform: 'uppercase', color: tone.soft, fontWeight: 600,
        }}>{label}</div>
      )}

      <div style={{ position: 'relative', flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
        {children}
      </div>

      {footer && (
        <div style={{
          fontFamily: treatment.mono, fontSize: 12.5, letterSpacing: '0.12em',
          textTransform: 'uppercase', color: tone.soft, fontWeight: 600,
        }}>{footer}</div>
      )}
    </div>
  );
}

// ── Cards ───────────────────────────────────────────────────

// Card 1: Cover
function CoverCard({ tone, treatment, active }) {
  const titleFamily =
    treatment.titleFont === 'serif' ? treatment.serif : treatment.sans;
  const isSerif = treatment.titleFont === 'serif';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label={`Annual report · ${DATA.windowLabel || DATA.year}`}
      footer="swipe to begin →">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', paddingBottom: 12 }}>
        <div style={{
          fontFamily: titleFamily,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 76, lineHeight: 0.92,
          letterSpacing: isSerif ? '-0.02em' : '-0.04em',
          textWrap: 'balance',
        }}>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 100ms' }}>Your</div>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 220ms' }}>Texting</div>
          <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)', transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 340ms' }}>Wrapped</div>
          <div style={{
            opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(20px)',
            transition: 'all 700ms cubic-bezier(.2,.7,.2,1) 460ms',
            fontFamily: treatment.mono, fontSize: 18, letterSpacing: '0.05em', marginTop: 18, fontWeight: 500, fontStyle: 'normal',
          }}>{DATA.windowLabel || DATA.year}</div>
        </div>
      </div>
    </CardShell>
  );
}

// Card 2: Hero number — total texts
function VolumeCard({ tone, treatment, active, instant }) {
  const n = useCountUp(DATA.totalSent, 1400, active, 150, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const perDay = DATA.totalSent ? Math.round(DATA.totalSent / 365) : null;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="01 · the volume"
      footer={perDay ? `that's ~${perDay} a day, every day.` : 'across every thread on your phone.'}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ fontSize: 14, letterSpacing: '0.12em', textTransform: 'uppercase', fontFamily: treatment.mono, color: tone.soft, marginBottom: 14 }}>
          You sent
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 108, lineHeight: 0.88,
          letterSpacing: isSerif ? '-0.045em' : '-0.06em',
          marginBottom: 12,
          whiteSpace: 'nowrap',
        }}>
          {fmt(n)}
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 38, lineHeight: 1.0,
          letterSpacing: isSerif ? '-0.02em' : '-0.03em',
        }}>
          texts.
        </div>
        <div style={{ marginTop: 24, fontFamily: treatment.mono, fontSize: 13, color: tone.soft, letterSpacing: '0.04em' }}>
          across iMessage + WhatsApp
        </div>
      </div>
    </CardShell>
  );
}

// Card 3: Top People — your most-texted (up to 10). A personal "keep" card,
// not built for public sharing (it shows names) — excluded from Share-all.
function PeopleCard({ tone, treatment, active }) {
  const people = (DATA.topPeople || []).slice(0, 10);
  const max = people.length ? people[0].count : 1;
  const isSerif = treatment.titleFont === 'serif';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="02 · your inner circle"
      footer="ranked by messages you sent.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 38, lineHeight: 0.95,
          letterSpacing: isSerif ? '-0.025em' : '-0.04em',
          marginBottom: 18,
        }}>
          Top {people.length} people, past year.
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          {people.map((p, i) => {
            const pct = (p.count / max) * 100;
            return (
              <div key={p.name + i} style={{
                opacity: active ? 1 : 0, transform: active ? 'translateX(0)' : 'translateX(-10px)',
                transition: `all 420ms cubic-bezier(.2,.7,.2,1) ${150 + i * 55}ms`,
              }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 3 }}>
                  <span style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, width: 20, fontWeight: 500, flexShrink: 0 }}>{String(i + 1).padStart(2, '0')}</span>
                  <span style={{
                    fontFamily: isSerif ? treatment.serif : treatment.sans,
                    fontWeight: isSerif ? 500 : 600,
                    fontSize: 17, letterSpacing: '-0.01em',
                    flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                  }}>{p.name}</span>
                  <span style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, fontWeight: 500, flexShrink: 0 }}>
                    {p.count.toLocaleString()} sent
                  </span>
                </div>
                <div style={{ position: 'relative', height: 3, background: 'currentColor', opacity: 0.28, marginLeft: 30, borderRadius: 2 }}>
                  <div style={{
                    position: 'absolute', left: 0, top: 0, bottom: 0,
                    width: active ? `${pct}%` : 0,
                    background: 'currentColor', borderRadius: 2,
                    transition: `width 800ms cubic-bezier(.2,.7,.2,1) ${230 + i * 55}ms`,
                  }}/>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </CardShell>
  );
}

// Card 2b: Past-30-day Top 10. Same surface as PeopleCard but bounded to the
// last 30 days — pairs with the annual ranking to show what's hot right now
// vs. who you've been talking to all year. Personal-only (omitted from
// public share-all composite, same as PeopleCard).
function PeopleL30Card({ tone, treatment, active }) {
  const people = (DATA.topPeopleL30 || []).slice(0, 10);
  const max = people.length ? people[0].count : 1;
  const isSerif = treatment.titleFont === 'serif';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="02b · the last 30 days"
      footer="ranked by messages you sent this month.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 700,
          fontSize: 38, lineHeight: 0.95,
          letterSpacing: isSerif ? '-0.025em' : '-0.04em',
          marginBottom: 18,
        }}>
          Top {people.length} people, past 30 days.
        </div>
        {people.length === 0 ? (
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 500,
            fontSize: 22, color: tone.soft, letterSpacing: '-0.01em',
          }}>Quiet month — no 1:1 sends in the last 30 days.</div>
        ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          {people.map((p, i) => {
            const pct = (p.count / max) * 100;
            return (
              <div key={p.name + i} style={{
                opacity: active ? 1 : 0, transform: active ? 'translateX(0)' : 'translateX(-10px)',
                transition: `all 420ms cubic-bezier(.2,.7,.2,1) ${150 + i * 55}ms`,
              }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 3 }}>
                  <span style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, width: 20, fontWeight: 500, flexShrink: 0 }}>{String(i + 1).padStart(2, '0')}</span>
                  <span style={{
                    fontFamily: isSerif ? treatment.serif : treatment.sans,
                    fontWeight: isSerif ? 500 : 600,
                    fontSize: 17, letterSpacing: '-0.01em',
                    flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                  }}>{p.name}</span>
                  <span style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, fontWeight: 500, flexShrink: 0 }}>
                    {p.count.toLocaleString()} sent
                  </span>
                </div>
                <div style={{ position: 'relative', height: 3, background: 'currentColor', opacity: 0.28, marginLeft: 30, borderRadius: 2 }}>
                  <div style={{
                    position: 'absolute', left: 0, top: 0, bottom: 0,
                    width: active ? `${pct}%` : 0,
                    background: 'currentColor', borderRadius: 2,
                    transition: `width 800ms cubic-bezier(.2,.7,.2,1) ${230 + i * 55}ms`,
                  }}/>
                </div>
              </div>
            );
          })}
        </div>
        )}
      </div>
    </CardShell>
  );
}

// Card 2c: Talker or Listener. Compares total OUTBOUND words vs INBOUND
// words across 1:1 threads. A big "X% talker" headline with a position on the
// listener ↔ talker scale, plus three highlight relationships (most balanced,
// you talk more, you listen more) so the aggregate gets context. Personal-
// only (names in highlights) → excluded from public share-all composite.
function TalkerListenerCard({ tone, treatment, active, instant }) {
  const t = DATA.talkListen || {};
  const pct = useCountUp(t.your_share_pct || 50, 1200, active, 200, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const verdict =
    (t.your_share_pct >= 55) ? 'talker' :
    (t.your_share_pct <= 45) ? 'listener' : 'balanced';
  const hi = t.highlights || {};
  const row = (label, person) => person && (
    <div style={{
      paddingTop: 10, paddingBottom: 10,
      borderTop: `1px solid ${tone.ink}`,
    }}>
      <div style={{
        fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.1em',
        textTransform: 'uppercase', color: tone.soft, fontWeight: 600,
        marginBottom: 4,
      }}>{label}</div>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 10 }}>
        <span style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontWeight: isSerif ? 500 : 600,
          fontSize: 18, letterSpacing: '-0.01em',
          flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{person.name}</span>
        <span style={{
          fontFamily: treatment.mono, fontSize: 12, color: tone.soft,
          fontWeight: 600, flexShrink: 0,
        }}>{person.your_share_pct}% your words</span>
      </div>
    </div>
  );
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="02c · talker or listener"
      footer="by word count, not message count.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          Of every word in your 1:1 threads, you wrote
        </div>

        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, whiteSpace: 'nowrap' }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 700,
            fontSize: 120, lineHeight: 0.85,
            letterSpacing: isSerif ? '-0.045em' : '-0.07em',
          }}>{fmt(pct, 0)}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 600, fontSize: 48, letterSpacing: '-0.04em',
          }}>%</div>
          <div style={{
            marginLeft: 10,
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: isSerif ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 600, fontSize: 36, letterSpacing: '-0.02em',
          }}>{verdict}</div>
        </div>

        {/* Scale: listener ← balanced → talker, marker at user's % */}
        <div style={{ position: 'relative', marginTop: 4 }}>
          <div style={{ position: 'relative', height: 12, borderRadius: 8, background: 'currentColor', opacity: 0.16, overflow: 'visible' }}/>
          <div style={{ position: 'absolute', left: '50%', top: -7, bottom: -7, width: 2, background: tone.ink, opacity: 0.55 }} />
          <div style={{
            position: 'absolute',
            left: `calc(${active ? Math.min(98, Math.max(2, t.your_share_pct || 50)) : 50}% - 8px)`,
            top: -3, width: 18, height: 18, borderRadius: 9,
            background: tone.ink,
            transition: 'left 1000ms cubic-bezier(.2,.7,.2,1) 200ms',
            boxShadow: `0 0 0 3px ${tone.bg}`,
          }} />
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 14, fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.06em', color: tone.soft, textTransform: 'uppercase' }}>
            <span>listener</span><span>balanced</span><span>talker</span>
          </div>
        </div>

        <div style={{ marginTop: 6 }}>
          {row('Most balanced', hi.most_balanced)}
          {row('You talk more', hi.most_you_talk)}
          {row('You listen more', hi.most_you_listen)}
        </div>
      </div>
    </CardShell>
  );
}

// Reply-time distribution — a right-skewed (lognormal-ish) curve: a tall spike
// near the median, a long tail out past the mean. Median + mean drawn as lines.
function LatencyCurve({ median, mean }) {
  const W = 320, H = 108, base = H - 2, top = 16;
  const med = Math.max(median, 0.1);
  // Crop the x-axis to the BODY of the distribution (a few medians wide) so the
  // bell sits in frame. The long outlier tail is trimmed; if the outlier-dragged
  // mean falls off-frame, we pin its marker at the right edge with an arrow.
  const xmax = Math.max(med * 6, 8);
  const xOf = (v) => Math.min(v / xmax, 1) * W;
  const sigma = 0.85;
  const f = (v) => Math.exp(-Math.pow(Math.log(v + 1) - Math.log(med + 1), 2) / (2 * sigma * sigma));
  const N = 80;
  let peak = 0;
  const ys = [];
  for (let i = 0; i <= N; i++) { const y = f((i / N) * xmax); ys.push(y); if (y > peak) peak = y; }
  const yOf = (y) => base - (y / peak) * (base - top);
  let d = `M0 ${base}`;
  for (let i = 0; i <= N; i++) d += ` L${((i / N) * W).toFixed(1)} ${yOf(ys[i]).toFixed(1)}`;
  d += ` L${W} ${base} Z`;
  const meanOff = mean > xmax;
  const xMean = meanOff ? W - 1.5 : xOf(mean);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ display: 'block', overflow: 'visible' }}>
      <path d={d} fill="currentColor" fillOpacity="0.16" stroke="currentColor" strokeOpacity="0.5" strokeWidth="1.5" />
      <line x1={xOf(median)} y1={top - 8} x2={xOf(median)} y2={base} stroke="currentColor" strokeWidth="2.5" />
      <line x1={xMean} y1={top - 8} x2={xMean} y2={base} stroke="currentColor" strokeOpacity="0.65" strokeWidth="1.5" strokeDasharray="3 3" />
      {meanOff && <path d={`M${W - 7} ${top - 4} L${W - 1} ${top} L${W - 7} ${top + 4} Z`} fill="currentColor" fillOpacity="0.65" />}
    </svg>
  );
}

// Card 4: Reply latency — distribution curve + plain-language mean vs median
function LatencyCard({ tone, treatment, active }) {
  const isSerif = treatment.numberFont === 'serif';
  const med = DATA.median, mean = DATA.mean;
  const skew = mean > med * 1.5;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="03 · the latency"
      footer="fast on the first reply. slow on the follow-through.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 20 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          How fast you reply
        </div>

        <div style={{ opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(10px)', transition: 'all 700ms ease 200ms' }}>
          <LatencyCurve median={med} mean={mean} />
          <div style={{ display: 'flex', gap: 20, marginTop: 10, fontFamily: treatment.mono, fontSize: 11, letterSpacing: '0.04em', color: tone.soft }}>
            <span><b style={{ color: tone.ink }}>│</b> median {fmt(med, 1)} min</span>
            <span>┊ mean {fmt(mean, 1)} min{mean > med * 6 ? ' →' : ''}</span>
          </div>
        </div>

        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 24, lineHeight: 1.22, letterSpacing: 0,
          wordSpacing: isSerif ? '0.05em' : 0, textWrap: 'balance',
        }}>
          {skew
            ? <>Half your replies land within <span style={{ textDecoration: 'underline', textUnderlineOffset: 5 }}>{fmt(med, 1)} minutes</span>. But your average is {fmt(mean, 1)} — a handful of slow ones drag the tail way out.</>
            : <>Half your replies land within <span style={{ textDecoration: 'underline', textUnderlineOffset: 5 }}>{fmt(med, 1)} minutes</span>, and your average ({fmt(mean, 1)}) isn't far off. You reply at a steady clip.</>}
        </div>
      </div>
    </CardShell>
  );
}

// Card 5: Ball in your court — its own frame. A gauge with a clear midpoint line.
function BallInCourtCard({ tone, treatment, active, instant }) {
  const pct = useCountUp(DATA.ballInCourt, 1200, active, 200, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const heavy = DATA.ballInCourt >= 50;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="04 · ball in your court"
      footer="where you ended the thread.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 26 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          Threads where you had the last word
        </div>

        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, whiteSpace: 'nowrap' }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 700,
            fontSize: 132, lineHeight: 0.85,
            letterSpacing: isSerif ? '-0.045em' : '-0.07em',
          }}>{fmt(pct)}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal',
            fontWeight: isSerif ? 400 : 600, fontSize: 52, letterSpacing: '-0.04em',
          }}>%</div>
        </div>

        {/* Gauge: fill to the user's %, with a clear midpoint (50%) reference
            line. Background bar and fill use independent rgba opacities — a
            single parent-level `opacity` would cascade to the fill child and
            collapse the contrast (the bug that made the fill invisible). */}
        <div style={{ position: 'relative', marginTop: 18 }}>
          <div style={{ position: 'relative', height: 14, borderRadius: 8, background: tone.ink + '2e', overflow: 'hidden' }}>
            <div style={{
              position: 'absolute', left: 0, top: 0, bottom: 0,
              width: active ? `${Math.min(DATA.ballInCourt, 100)}%` : 0,
              background: tone.ink, borderRadius: 8,
              transition: 'width 1000ms cubic-bezier(.2,.7,.2,1) 200ms',
            }}/>
          </div>
          <div style={{ position: 'absolute', left: '50%', top: -7, bottom: -7, width: 2, background: tone.ink, opacity: 0.85 }} />
          <div style={{ position: 'absolute', left: '50%', top: -24, transform: 'translateX(-50%)', fontFamily: treatment.mono, fontSize: 9.5, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft }}>even</div>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 10, fontFamily: treatment.mono, fontSize: 10, letterSpacing: '0.06em', color: tone.soft }}>
            <span>they had it last</span><span>you had it last</span>
          </div>
        </div>

        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 26, lineHeight: 1.18, letterSpacing: 0,
          wordSpacing: isSerif ? '0.05em' : 0, textWrap: 'balance',
        }}>
          {heavy
            ? 'You sent the last message in most of your live threads.'
            : "More often, the other side had the last word."}
        </div>
      </div>
    </CardShell>
  );
}

function Stat({ treatment, tone, value, label }) {
  return (
    <div style={{ paddingTop: 10, borderTop: `1px solid ${tone.ink}` }}>
      <div style={{
        fontFamily: treatment.numberFont === 'serif' ? treatment.serif : treatment.sans,
        fontWeight: treatment.numberFont === 'serif' ? 400 : 700,
        fontStyle: treatment.italicNumbers ? 'italic' : 'normal',
        fontSize: 36, lineHeight: 1, letterSpacing: '-0.03em',
      }}>{value}</div>
      <div style={{ marginTop: 4, fontFamily: treatment.mono, fontSize: 11, color: tone.soft, letterSpacing: '0.06em', textTransform: 'uppercase' }}>
        {label}
      </div>
    </div>
  );
}

// Card 5: Group chat reveal
function GroupsCard({ tone, treatment, active, instant }) {
  const pct = useCountUp(DATA.groupContribPct, 1100, active, 180, instant);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="05 · the ghost data"
      footer="the receipts don't lie.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22 }}>
        <div>
          <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 8 }}>
            Your share of every group thread
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, flexWrap: 'nowrap', whiteSpace: 'nowrap' }}>
            <div style={{
              fontFamily: isSerif ? treatment.serif : treatment.sans,
              fontStyle: italic ? 'italic' : 'normal',
              fontWeight: isSerif ? 400 : 700,
              fontSize: 132, lineHeight: 0.85,
              letterSpacing: isSerif ? '-0.045em' : '-0.07em',
              paddingRight: isSerif ? 14 : 0,
            }}>{pct.toFixed(1)}</div>
            <div style={{
              fontFamily: isSerif ? treatment.serif : treatment.sans,
              fontStyle: italic ? 'italic' : 'normal',
              fontWeight: isSerif ? 400 : 600,
              fontSize: 52, letterSpacing: '-0.04em',
            }}>%</div>
          </div>
        </div>

        <div style={{
          paddingTop: 16, borderTop: `1px solid ${tone.ink}`,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 600,
          fontSize: 30, lineHeight: 1.1, letterSpacing: 0,
          wordSpacing: isSerif ? '0.05em' : 0, textWrap: 'balance',
        }}>
          Silent in <span style={{ textDecoration: 'underline', textUnderlineOffset: 6 }}>{DATA.silentGroups} of {DATA.totalGroups}</span> groups.
        </div>

        {DATA.worstGhost && (
          <div style={{
            padding: '14px 16px',
            border: `1px solid ${tone.ink}`,
            opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(8px)',
            transition: 'all 600ms ease 700ms',
          }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.08em', textTransform: 'uppercase', color: tone.soft, marginBottom: 4 }}>
              Top offender · "{DATA.worstGhost.name}"
            </div>
            <div style={{ fontFamily: treatment.mono, fontSize: 14, fontWeight: 500 }}>
              {DATA.worstGhost.messages.toLocaleString()} messages. You sent {DATA.worstGhost.userSent != null ? DATA.worstGhost.userSent : 0}.
            </div>
          </div>
        )}
      </div>
    </CardShell>
  );
}

// Card 6: Archetype
function ArchetypeCard({ tone, treatment, active }) {
  const isSerif = treatment.titleFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  const lines = DATA.archetype.name.split(' ');
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="08 · your archetype"
      footer={`fits ${DATA.archetype.why}`}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 14 }}>
          You are
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: italic ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 800,
          fontSize: 86, lineHeight: 0.86,
          letterSpacing: isSerif ? '-0.04em' : '-0.06em',
        }}>
          {lines.map((w, i) => (
            <div key={i} style={{
              opacity: active ? 1 : 0,
              transform: active ? 'translateY(0)' : 'translateY(18px)',
              transition: `all 700ms cubic-bezier(.2,.7,.2,1) ${300 + i * 160}ms`,
            }}>{w}</div>
          ))}
        </div>
        <div style={{
          marginTop: 28, paddingTop: 18, borderTop: `1px solid ${tone.ink}`,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 500,
          fontSize: 22, lineHeight: 1.2, letterSpacing: 0,
          wordSpacing: isSerif ? '0.05em' : 0,
          opacity: active ? 1 : 0, transition: 'opacity 800ms ease 900ms',
        }}>
          {DATA.archetype.verdict}
        </div>
      </div>
    </CardShell>
  );
}

// Card 7: Share — pure creative. The share CTA lives in the page chrome
// (App's control bar), not on the card, so the shared image stays clean.
function ShareCard({ tone, treatment, active }) {
  const isSerif = treatment.titleFont === 'serif';
  // Richer recap — one hero number per card in the deck. Names get redacted
  // (just counts) since the recap is included in the public Share-all
  // composite; the people cards themselves stay personal-only.
  const tiles = [];
  if (DATA.totalSent) tiles.push({ stat: fmt(DATA.totalSent), label: 'texts sent' });
  if (DATA.topPeople && DATA.topPeople[0]) {
    const top = DATA.topPeople[0];
    tiles.push({ stat: top.name, label: `top contact · ${fmt(top.count)}` });
  }
  if (DATA.topPeopleL30 && DATA.topPeopleL30[0]) {
    const top = DATA.topPeopleL30[0];
    tiles.push({ stat: top.name, label: `last 30d · ${fmt(top.count)}` });
  }
  if (DATA.talkListen && DATA.talkListen.your_share_pct != null) {
    tiles.push({ stat: `${Math.round(DATA.talkListen.your_share_pct)}%`, label: 'talker share' });
  }
  tiles.push({ stat: `${fmt(DATA.median, 1)}m`, label: 'median reply' });
  tiles.push({ stat: `${fmt(DATA.mean, 1)}m`, label: 'average reply' });
  tiles.push({ stat: `${DATA.ballInCourt}%`, label: 'last word' });
  tiles.push({ stat: `${Number(DATA.groupContribPct).toFixed(1)}%`, label: 'group share' });
  const emojiTop = (DATA.emoji && (DATA.emoji.top_inline || DATA.emoji.top)) || [];
  if (emojiTop[0]) tiles.push({ stat: emojiTop[0].emoji, label: 'top emoji' });
  if (DATA.age && DATA.age.estimated_age != null) tiles.push({ stat: `${DATA.age.estimated_age}`, label: 'texting age' });
  // 10 max — keeps the fully populated recap as a clean two-column grid, and
  // falls back gracefully if some analyses lack people / age / emoji blocks.
  const recap = tiles.slice(0, 10);
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label={`Wrapped · ${DATA.windowLabel || DATA.year}`}
      footer="sunriselabs.ai · textingwrapped.com">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft, marginBottom: 10 }}>
          The year, in one card
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal',
          fontWeight: isSerif ? 400 : 800,
          fontSize: 46, lineHeight: 0.9,
          letterSpacing: isSerif ? '-0.03em' : '-0.05em',
          textWrap: 'balance',
        }}>
          {DATA.archetype.name}
        </div>
        <div style={{
          marginTop: 8, marginBottom: 20,
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 500,
          fontSize: 18, lineHeight: 1.2, color: tone.soft, letterSpacing: 0,
          wordSpacing: isSerif ? '0.05em' : 0, textWrap: 'balance',
        }}>
          {DATA.archetype.verdict}
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: 10 }}>
          {recap.map((r, i) => (
            <RecapTile key={i} treatment={treatment} tone={tone} stat={r.stat} label={r.label} />
          ))}
        </div>
      </div>
    </CardShell>
  );
}

function RecapTile({ treatment, tone, stat, label }) {
  const isSerif = treatment.numberFont === 'serif';
  // Auto-shrink long stats (contact names) so the grid stays even.
  const s = String(stat);
  const fontSize = s.length > 18 ? 16 : s.length > 12 ? 20 : s.length > 8 ? 24 : 28;
  return (
    <div style={{
      padding: '14px 14px 12px',
      border: `1px solid ${tone.ink}`,
      boxSizing: 'border-box',
      minWidth: 0,
      minHeight: 70,
    }}>
      <div style={{
        fontFamily: isSerif ? treatment.serif : treatment.sans,
        fontStyle: treatment.italicNumbers ? 'italic' : 'normal',
        fontWeight: isSerif ? 400 : 700,
        fontSize, lineHeight: 1.05, letterSpacing: '-0.02em',
        wordSpacing: treatment.italicNumbers ? '0.05em' : 0,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
      }}>{stat}</div>
      <div style={{ marginTop: 4, fontFamily: treatment.mono, fontSize: 10, color: tone.soft, letterSpacing: '0.08em', textTransform: 'uppercase' }}>
        {label}
      </div>
    </div>
  );
}

// Card 6: Emoji — split into INLINE emoji (typed in messages) vs REACTIONS
// (tapbacks). A 👍 tapback is qualitatively different from a 👍 typed in line.
// Falls back to the legacy single-list `top` field for older analysis.json.
function EmojiRow({ row, isSerif, tone, treatment, active, baseDelay }) {
  return (
    <div style={{ display: 'flex', gap: 14, alignItems: 'flex-end' }}>
      {row.map((t, i) => (
        <div key={i} style={{
          textAlign: 'center',
          opacity: active ? 1 : 0, transform: active ? 'translateY(0)' : 'translateY(10px)',
          transition: `all 500ms cubic-bezier(.2,.7,.2,1) ${baseDelay + i * 70}ms`,
        }}>
          <div style={{ fontSize: i === 0 ? 38 : 30, lineHeight: 1 }}>{t.emoji}</div>
          <div style={{ fontFamily: treatment.mono, fontSize: 10, color: tone.soft, marginTop: 5 }}>{t.count.toLocaleString()}</div>
        </div>
      ))}
    </div>
  );
}

function EmojiCard({ tone, treatment, active, instant }) {
  const e = DATA.emoji || { pct_messages_with_emoji: 0 };
  const pct = useCountUp(e.pct_messages_with_emoji, 1100, active, 180, instant);
  const inline = (e.top_inline || e.top || []).slice(0, 5);
  const reactions = (e.top_reactions || []).slice(0, 5);
  const isSerif = treatment.numberFont === 'serif';
  const italic = isSerif && treatment.italicNumbers;
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="06 · your emoji"
      footer="typed vs tapbacked.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 16 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          You drop an emoji in
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 700,
            fontSize: 108, lineHeight: 0.85, letterSpacing: isSerif ? '-0.045em' : '-0.07em',
          }}>{fmt(pct, pct % 1 ? 1 : 0)}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: italic ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
            fontSize: 40, letterSpacing: '-0.04em',
          }}>%</div>
        </div>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, color: tone.soft, letterSpacing: '0.04em', marginTop: -4 }}>
          of your inline messages.
        </div>

        {inline.length > 0 && (
          <div style={{ marginTop: 8 }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft, marginBottom: 8, fontWeight: 600 }}>
              Top 5 inline
            </div>
            <EmojiRow row={inline} isSerif={isSerif} tone={tone} treatment={treatment} active={active} baseDelay={250} />
          </div>
        )}

        {reactions.length > 0 && (
          <div style={{ marginTop: 6 }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 10.5, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft, marginBottom: 8, fontWeight: 600 }}>
              Top 5 reactions
            </div>
            <EmojiRow row={reactions} isSerif={isSerif} tone={tone} treatment={treatment} active={active} baseDelay={450} />
          </div>
        )}
      </div>
    </CardShell>
  );
}

// Card 7: Texting age — playful, probabilistic (from age_estimate.py via the
// research rubric). Omitted unless analysis.json carries an `age` block.
function AgeCard({ tone, treatment, active }) {
  const a = DATA.age || { label: '—', estimated_age: null, approx_age: '', drivers: [] };
  const isSerif = treatment.titleFont === 'serif';
  const drivers = (a.drivers || []).slice(0, 3);
  const confidence = a.confidence ? `${a.confidence}-confidence style read` : 'playful style read';
  const sample = a.sample_size ? ` · ${a.sample_size.toLocaleString()} texts sampled` : '';
  return (
    <CardShell
      tone={tone} treatment={treatment}
      label="07 · your texting age"
      footer="a guarded estimate from your writing-style signals.">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 16 }}>
        <div style={{ fontFamily: treatment.mono, fontSize: 12, letterSpacing: '0.12em', textTransform: 'uppercase', color: tone.soft }}>
          You text like a
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, whiteSpace: 'nowrap' }}>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 800,
            fontSize: 120, lineHeight: 0.85, letterSpacing: isSerif ? '-0.04em' : '-0.06em',
          }}>{a.estimated_age != null ? a.estimated_age : '—'}</div>
          <div style={{
            fontFamily: isSerif ? treatment.serif : treatment.sans,
            fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
            fontSize: 28, letterSpacing: '-0.02em',
          }}>-year-old</div>
        </div>
        <div style={{
          fontFamily: isSerif ? treatment.serif : treatment.sans,
          fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
          fontSize: 24, letterSpacing: 0, wordSpacing: isSerif ? '0.05em' : 0,
        }}>{a.label} texting energy</div>
        {a.approx_age && (
          <div style={{ fontFamily: treatment.mono, fontSize: 12, color: tone.soft, letterSpacing: '0.06em' }}>
            that band typically runs {a.approx_age}
          </div>
        )}
        <div style={{ fontFamily: treatment.mono, fontSize: 11, color: tone.soft, letterSpacing: '0.06em', textTransform: 'uppercase' }}>
          {confidence}{sample}
        </div>
        {drivers.length > 0 && (
          <div style={{ marginTop: 8, paddingTop: 16, borderTop: `1px solid ${tone.ink}` }}>
            <div style={{ fontFamily: treatment.mono, fontSize: 11, letterSpacing: '0.1em', textTransform: 'uppercase', color: tone.soft, marginBottom: 10 }}>
              Style signals
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              {drivers.map((d, i) => (
                <div key={i} style={{
                  fontFamily: isSerif ? treatment.serif : treatment.sans,
                  fontStyle: isSerif ? 'italic' : 'normal', fontWeight: isSerif ? 400 : 600,
                  fontSize: 19, lineHeight: 1.15, letterSpacing: 0,
                  wordSpacing: isSerif ? '0.05em' : 0,
                  opacity: active ? 1 : 0, transform: active ? 'translateX(0)' : 'translateX(-10px)',
                  transition: `all 500ms cubic-bezier(.2,.7,.2,1) ${200 + i * 90}ms`,
                }}>{d}</div>
              ))}
            </div>
          </div>
        )}
      </div>
    </CardShell>
  );
}

// ── Carousel ────────────────────────────────────────────────

const CARDS_BY_KEY = {
  cover: CoverCard, volume: VolumeCard, people: PeopleCard, people_l30: PeopleL30Card,
  talk_listen: TalkerListenerCard,
  latency: LatencyCard, ballincourt: BallInCourtCard, groups: GroupsCard, emoji: EmojiCard,
  age: AgeCard, archetype: ArchetypeCard, share: ShareCard,
};

// Palette is decoupled from card order so adding/omitting cards never recolors
// the others. Each key maps to an index into the treatment's palette array;
// emoji + age reuse earlier slots (people/volume) to avoid extra palettes.
// people_l30 + talk_listen reuse people's palette so the three sister cards
// visually rhyme.
const PALETTE_OF = {
  cover: 0, volume: 1, people: 2, people_l30: 2, talk_listen: 2,
  latency: 3, ballincourt: 4,
  groups: 5, archetype: 6, share: 7, emoji: 2, age: 1,
};

// Active cards: from DATA.cards if provided, else the full arc. Module-level
// and recomputed by setActiveWindow when the user toggles past-year ↔ all-time
// (each dataset can populate a different card set).
function computeCardKeys(d) {
  return ((d.cards && d.cards.length) ? d.cards : FULL_ARC).filter((k) => CARDS_BY_KEY[k]);
}
function computeCards(keys) {
  return keys.map((k) => ({ Comp: CARDS_BY_KEY[k], paletteIdx: PALETTE_OF[k] != null ? PALETTE_OF[k] : 0 }));
}
let CARD_KEYS = computeCardKeys(DATA);
let CARDS = computeCards(CARD_KEYS);

function setActiveWindow(key) {
  const next = datasetFor(key);
  if (!next) return false;
  DATA = next;
  CARD_KEYS = computeCardKeys(DATA);
  CARDS = computeCards(CARD_KEYS);
  return true;
}

function slugPart(value) {
  return String(value || 'card')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    || 'card';
}

function cardExportName(index, extension = 'png') {
  const cardKey = CARD_KEYS[index] || 'card';
  const n = String(index + 1).padStart(2, '0');
  return `texting-wrapped-${DATA.year}-${n}-${slugPart(cardKey)}.${extension}`;
}

function allCardsExportName(extension = 'png') {
  return `texting-wrapped-${DATA.year}-all-cards.${extension}`;
}

function shareableCardIndices() {
  return CARD_KEYS
    .map((key, index) => ({ key, index }))
    .filter(({ key }) => key !== 'people' && key !== 'people_l30' && key !== 'talk_listen')
    .map(({ index }) => index);
}

function activeCaptureMetadata(index) {
  const target = document.querySelector('[data-wrapped-capture-active="true"]');
  if (!target) return null;
  const rect = target.getBoundingClientRect();
  return {
    index,
    key: CARD_KEYS[index] || 'card',
    filename: cardExportName(index),
    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
  };
}

// Controlled: idx + go come from App, so navigation controls can live in the
// page chrome (off the creative). captureRef points at the active card so App's
// Share can snapshot just the card art.
function Carousel({ treatment, idx, go, captureRef, instant }) {
  const [drag, setDrag] = useState(null); // {startX, dx}
  const [w, setW] = useState(402);
  const ref = useRef(null);

  // Measure carousel width so we can translate in pixels (avoids calc bugs)
  useEffect(() => {
    const measure = () => { if (ref.current) setW(ref.current.offsetWidth); };
    measure();
    const ro = new ResizeObserver(measure);
    if (ref.current) ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);

  // keyboard
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'ArrowRight') go(idx + 1);
      else if (e.key === 'ArrowLeft') go(idx - 1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [idx, go]);

  // Pointer drag
  const onPointerDown = (e) => {
    setDrag({ startX: e.clientX, dx: 0 });
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e) => {
    if (!drag) return;
    setDrag({ ...drag, dx: e.clientX - drag.startX });
  };
  const onPointerUp = () => {
    if (!drag) return;
    const { dx } = drag;
    if (Math.abs(dx) > 50) {
      if (dx < 0) go(idx + 1); else go(idx - 1);
    }
    setDrag(null);
  };

  // tap zones
  const onCardTap = (e) => {
    const rect = ref.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    if (x < rect.width * 0.35) go(idx - 1);
    else if (x > rect.width * 0.65) go(idx + 1);
  };

  return (
    <div
      ref={ref}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      style={{
        position: 'absolute', inset: 0,
        overflow: 'hidden',
        touchAction: 'pan-y',
        userSelect: 'none',
        cursor: drag ? 'grabbing' : 'default',
      }}>
      {/* Card stack — each card is PURE creative (no controls baked in). The
          active card's wrapper is the capture target for sharing. */}
      {CARDS.map(({ Comp, paletteIdx }, i) => {
        const offset = i - idx;
        const dragOffset = (drag && i === idx) ? drag.dx : 0;
        const isActive = i === idx;
        const visible = Math.abs(offset) <= 1 || drag;
        return (
          <div key={i}
            ref={isActive ? (el) => { if (captureRef) captureRef.current = el; } : undefined}
            data-wrapped-capture-card={CARD_KEYS[i]}
            data-wrapped-capture-active={isActive ? 'true' : undefined}
            style={{
              position: 'absolute', inset: 0,
              transform: `translate3d(${offset * w + dragOffset}px, 0, 0)`,
              transition: drag ? 'none' : 'transform 520ms cubic-bezier(.22,.61,.36,1), opacity 520ms ease',
              opacity: visible ? 1 : 0,
              pointerEvents: isActive ? 'auto' : 'none',
            }}>
            <Comp
              tone={treatment.cards[paletteIdx]}
              treatment={treatment}
              active={isActive}
              instant={instant}
              onTap={onCardTap}
            />
          </div>
        );
      })}

      {/* Top story-segment progress — subtle phone status, not a CTA. Excluded
          from the shared image (capture targets the card, not this overlay). */}
      <div style={{
        position: 'absolute', top: 58, left: 16, right: 16,
        display: 'flex', gap: 4, pointerEvents: 'none', zIndex: 10,
      }}>
        {CARDS.map((_, i) => (
          <div key={i} style={{
            flex: 1, height: 2.5, borderRadius: 2,
            background: 'rgba(0,0,0,0.18)',
            overflow: 'hidden',
            mixBlendMode: 'difference',
          }}>
            <div style={{
              height: '100%',
              width: i <= idx ? '100%' : '0%',
              background: 'rgba(255,255,255,0.95)',
              transition: 'width 360ms ease',
            }}/>
          </div>
        ))}
      </div>
    </div>
  );
}

// Chrome nav button (page chrome, off the creative)
function ChromeBtn({ children, onClick, disabled, aria }) {
  return (
    <button onClick={onClick} disabled={disabled} aria-label={aria} style={{
      width: 44, height: 44, borderRadius: 9999,
      border: '1px solid rgba(255,255,255,0.25)',
      background: 'rgba(255,255,255,0.08)', color: '#fff',
      fontSize: 22, lineHeight: 1, cursor: disabled ? 'default' : 'pointer',
      opacity: disabled ? 0.3 : 1,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
    }}>{children}</button>
  );
}

function NavigationHint() {
  const rows = [
    { glyph: '← / →', label: 'Arrow keys' },
    { glyph: '↔', label: 'Swipe or drag' },
  ];
  return (
    <div
      aria-label="Navigation guidance"
      style={{
        width: 190,
        padding: '15px 16px 14px',
        borderRadius: 22,
        border: '1px solid rgba(255,255,255,0.18)',
        background: 'rgba(255,255,255,0.08)',
        boxShadow: '0 18px 52px rgba(0,0,0,0.28)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        color: '#fff',
        fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
        textTransform: 'uppercase',
      }}>
      <div style={{
        fontSize: 11,
        fontWeight: 700,
        letterSpacing: '0.16em',
        opacity: 0.9,
        marginBottom: 12,
      }}>
        Navigate
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {rows.map((row) => (
          <div key={row.label} style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
            <div style={{
              minWidth: 46,
              height: 26,
              padding: '0 8px',
              borderRadius: 999,
              border: '1px solid rgba(255,255,255,0.18)',
              background: 'rgba(0,0,0,0.24)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 12,
              fontWeight: 800,
              letterSpacing: '0.06em',
              color: 'rgba(255,255,255,0.94)',
            }}>
              {row.glyph}
            </div>
            <div style={{
              fontSize: 10.5,
              fontWeight: 650,
              letterSpacing: '0.12em',
              color: 'rgba(255,255,255,0.72)',
              whiteSpace: 'nowrap',
            }}>
              {row.label}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── App ─────────────────────────────────────────────────────

function App() {
  // ONE canonical look — sunrise. The treatment picker is gone on purpose.
  const treatment = TREATMENTS.sunrise;

  // Past-year ↔ all-time. Both datasets ship inside this one file; the toggle
  // below switches them in place (default: past year).
  const [windowKey, setWindowKey] = useState(INITIAL_WINDOW);
  const hasWindowToggle = !!(datasetFor('past_year') && datasetFor('all_time'));

  // Navigation + share state live here so the controls render in the page
  // chrome (off the creative), not on the cards.
  const [idx, setIdx] = useState(0);
  const [shareState, setShareState] = useState('idle');
  const [exportState, setExportState] = useState('idle');
  const captureRef = useRef(null);
  useEffect(() => {
    notifyNative('loaded');
  }, []);
  const go = useCallback((n) => {
    setIdx((current) => {
      const next = Math.max(0, Math.min(CARDS.length - 1, n));
      if (next !== current) notifyNative('advance');
      return next;
    });
  }, []);

  // Swap the active metric window. Mutates the module-level DATA/CARDS then
  // remounts the carousel via key={windowKey} so every card re-reads it.
  const toggleWindow = useCallback(() => {
    const next = windowKey === 'past_year' ? 'all_time' : 'past_year';
    if (!setActiveWindow(next)) return;
    setIdx(0);
    setWindowKey(next);
    notifyNative('toggle_window');
  }, [windowKey]);

  const [capturing, setCapturing] = useState(false);
  const [shareAllState, setShareAllState] = useState('');
  const [exportAllState, setExportAllState] = useState('');
  const nativePreview = !!(typeof window !== 'undefined' && window.__MESSAGES_FOR_AI_NATIVE_PREVIEW);

  useEffect(() => {
    if (typeof window === 'undefined') return undefined;
    window.__messagesForAIWrappedSnapshot = {
      current: () => activeCaptureMetadata(idx),
      shareableIndices: () => shareableCardIndices(),
      allCardsFilename: () => allCardsExportName(),
      setIndex: (index) => {
        const next = Math.max(0, Math.min(CARDS.length - 1, Number(index) || 0));
        setIdx(next);
        return { index: next, key: CARD_KEYS[next] || 'card', filename: cardExportName(next) };
      },
    };
    return () => {
      if (window.__messagesForAIWrappedSnapshot?.current?.().index === idx) {
        delete window.__messagesForAIWrappedSnapshot;
      }
    };
  }, [idx]);

  const waitForFonts = useCallback(async () => {
    if (document.fonts && document.fonts.ready) {
      try { await document.fonts.ready; } catch (_) {}
    }
  }, []);

  const captureElementBlob = useCallback(async (el, scale = 3) => {
    if (!el || !window.html2canvas) return null;
    const W = 402, H = 874;
    const clone = el.cloneNode(true);
    Object.assign(clone.style, {
      position: 'fixed', left: '-9999px', top: '0',
      width: W + 'px', height: H + 'px', transform: 'none', inset: '',
    });
    document.body.appendChild(clone);
    try {
      await new Promise((r) => setTimeout(r, 50));
      const canvas = await window.html2canvas(clone, {
        scale, backgroundColor: null, useCORS: true, logging: false, width: W, height: H,
      });
      return await new Promise((res) => canvas.toBlob(res, 'image/png'));
    } finally {
      clone.remove();
    }
  }, []);

  const captureActiveCardBlob = useCallback(async () => {
    await waitForFonts();
    return await captureElementBlob(captureRef.current, 3);
  }, [captureElementBlob, waitForFonts]);

  const captureAllCardsBlob = useCallback(async (setProgress) => {
    if (!window.html2canvas || capturing) return null;
    const startIdx = idx;
    setCapturing(true);
    await waitForFonts();
    try {
      const shots = [];
      for (let i = 0; i < CARDS.length; i++) {
        if (CARD_KEYS[i] === 'people' || CARD_KEYS[i] === 'people_l30' || CARD_KEYS[i] === 'talk_listen') continue;
        setIdx(i);
        setProgress(`${i + 1}/${CARDS.length}`);
        await new Promise((r) => setTimeout(r, 800));
        const blob = await captureElementBlob(captureRef.current, 2);
        if (!blob) continue;
        const image = await blobToDrawable(blob);
        shots.push(image);
      }
      if (!shots.length) return null;
      const cols = shots.length <= 4 ? 2 : 3;
      const rows = Math.ceil(shots.length / cols);
      const scale = 360 / shots[0].width;
      const sw = Math.round(shots[0].width * scale), sh = Math.round(shots[0].height * scale);
      const gap = 18, pad = 28;
      const cvs = document.createElement('canvas');
      cvs.width = pad * 2 + cols * sw + (cols - 1) * gap;
      cvs.height = pad * 2 + rows * sh + (rows - 1) * gap;
      const ctx = cvs.getContext('2d');
      ctx.fillStyle = '#0a0a0c'; ctx.fillRect(0, 0, cvs.width, cvs.height);
      shots.forEach((img, i) => ctx.drawImage(img, pad + (i % cols) * (sw + gap), pad + Math.floor(i / cols) * (sh + gap), sw, sh));
      return await new Promise((res) => cvs.toBlob(res, 'image/png'));
    } finally {
      setCapturing(false);
      setIdx(startIdx);
    }
  }, [idx, capturing, captureElementBlob, waitForFonts]);

  const browserSaveOrShare = useCallback(async (blob, filename, preferShare, shareText) => {
    const file = new File([blob], filename, { type: 'image/png' });
    if (preferShare && navigator.canShare && navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file], title: 'My Texting Wrapped', text: shareText });
      return 'shared';
    }
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    return 'saved';
  }, []);

  const shareOrExportBlob = useCallback(async (blob, filename, mode, nativeAction, telemetryAction) => {
    const nativeAvailable = hasNativeWrappedFileBridge();
    if (nativeAvailable) {
      const result = await sendNativeWrappedFile({ action: nativeAction, filename, blob });
      return result.ok ? (mode === 'share' ? 'shared' : 'saved') : 'failed';
    }
    const result = await browserSaveOrShare(
      blob,
      filename,
      mode === 'share',
      nativeAction === 'share_all'
        ? 'My full Texting Wrapped · textingwrapped.com'
        : 'My Texting Wrapped · textingwrapped.com'
    );
    if (mode === 'share' && !nativeAvailable) notifyNative(telemetryAction);
    return result;
  }, [browserSaveOrShare]);

  const handleShare = useCallback(async () => {
    if (shareState === 'working' || exportState === 'working' || capturing) return;
    try {
      setShareState('working');
      const blob = await captureActiveCardBlob();
      if (!blob) { setShareState('failed'); return; }
      const result = await shareOrExportBlob(blob, cardExportName(idx), 'share', 'share_card', 'share');
      setShareState(result);
    } catch (_) {
      setShareState('failed');
    } finally {
      setTimeout(() => setShareState('idle'), 2200);
    }
  }, [idx, shareState, exportState, capturing, captureActiveCardBlob, shareOrExportBlob]);

  const handleExport = useCallback(async () => {
    if (shareState === 'working' || exportState === 'working' || capturing) return;
    try {
      setExportState('working');
      const blob = await captureActiveCardBlob();
      if (!blob) { setExportState('failed'); return; }
      const result = await shareOrExportBlob(blob, cardExportName(idx), 'export', 'export_card', 'share');
      setExportState(result === 'saved' ? 'saved' : 'failed');
    } catch (_) {
      setExportState('failed');
    } finally {
      setTimeout(() => setExportState('idle'), 2200);
    }
  }, [idx, shareState, exportState, capturing, captureActiveCardBlob, shareOrExportBlob]);

  const handleShareAll = useCallback(async () => {
    if (capturing) return;
    try {
      setShareAllState('rendering');
      const blob = await captureAllCardsBlob(setShareAllState);
      if (!blob) { setShareAllState('failed'); return; }
      const result = await shareOrExportBlob(blob, allCardsExportName(), 'share', 'share_all', 'share_all');
      setShareAllState(result === 'shared' ? 'done' : 'saved');
    } catch (_) {
      setShareAllState('failed');
    } finally {
      setTimeout(() => setShareAllState(''), 2500);
    }
  }, [capturing, captureAllCardsBlob, shareOrExportBlob]);

  const handleExportAll = useCallback(async () => {
    if (capturing) return;
    try {
      setExportAllState('rendering');
      const blob = await captureAllCardsBlob(setExportAllState);
      if (!blob) { setExportAllState('failed'); return; }
      const result = await shareOrExportBlob(blob, allCardsExportName(), 'export', 'export_all', 'share_all');
      setExportAllState(result === 'saved' ? 'done' : 'failed');
    } catch (_) {
      setExportAllState('failed');
    } finally {
      setTimeout(() => setExportAllState(''), 2500);
    }
  }, [capturing, captureAllCardsBlob, shareOrExportBlob]);

  // Scale the device to fit viewport (height-driven)
  const [scale, setScale] = useState(1);
  const [viewportWidth, setViewportWidth] = useState(typeof window !== 'undefined' ? window.innerWidth : 1200);
  useEffect(() => {
    const compute = () => {
      const PHONE_H = 874, PHONE_W = 402;
      // Reserve vertical room for the control bar that sits BELOW the frame.
      const sH = (window.innerHeight - (nativePreview ? 80 : 150)) / PHONE_H;
      const sW = (window.innerWidth - 80) / PHONE_W;
      setScale(Math.min(1, sH, sW));
      setViewportWidth(window.innerWidth);
    };
    compute();
    window.addEventListener('resize', compute);
    return () => window.removeEventListener('resize', compute);
  }, [nativePreview]);
  const currentBusy = shareState === 'working' || exportState === 'working' || capturing;
  const showNavigationHint = idx === 0 && !capturing;
  const navigationHintBeside = showNavigationHint && viewportWidth >= 900;

  return (
    <div style={{
      position: 'fixed', inset: 0,
      background: '#1c1a1f',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 20,
      overflow: 'hidden',
      fontFamily: '"Inter", system-ui, sans-serif',
    }}>
      {/* Stage backdrop — warm sunrise hue */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'radial-gradient(60% 50% at 50% 40%, rgba(255,140,90,0.20), transparent 70%), #1a1116',
      }}/>

      {/* Brand mark — bottom-left */}
      <div style={{
        position: 'absolute', bottom: 22, left: 24,
        color: 'rgba(255,255,255,0.5)',
        fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
        fontSize: 11, letterSpacing: '0.14em', textTransform: 'uppercase',
        zIndex: 5,
      }}>
        messages for ai · {DATA.windowLabel || DATA.year}
      </div>

      <div style={{
        position: 'absolute', bottom: 22, right: 24,
        color: 'rgba(255,255,255,0.5)',
        fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
        fontSize: 11, letterSpacing: '0.14em', textTransform: 'uppercase',
        zIndex: 5,
      }}>
        ← → · drag · tap edges
      </div>

      {/* Window toggle — top-right page chrome. Renders only when BOTH the
          past-year and all-time datasets were embedded by the pipeline; flips
          the whole story between them in place (default: past year). */}
      {hasWindowToggle && (
        <button
          onClick={toggleWindow}
          disabled={capturing}
          aria-label={windowKey === 'past_year' ? 'Show all time' : 'Show past year'}
          style={{
            position: 'absolute', top: 22, right: 24, zIndex: 6,
            height: 36, padding: '0 16px', borderRadius: 9999,
            border: '1px solid rgba(255,255,255,0.25)',
            background: 'rgba(255,255,255,0.08)',
            color: '#fff', cursor: capturing ? 'default' : 'pointer',
            backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
            display: 'flex', alignItems: 'center', gap: 8,
            fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
            fontSize: 11, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
          }}>
          ⇄ {windowKey === 'past_year' ? 'All time' : 'Past year'}
        </button>
      )}

      <div style={{
        position: 'relative',
        zIndex: 1,
        display: 'flex',
        flexDirection: navigationHintBeside ? 'row' : 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: navigationHintBeside ? 28 : 14,
      }}>
        {/* The phone — a sized box (scaled dims) so the control bar flows BELOW
            the frame instead of overlapping it. The iPhone is dedicated to the
            creative; nothing interactive sits on it. */}
        <div style={{ position: 'relative', width: 402 * scale, height: 874 * scale }}>
          <div style={{ width: 402, height: 874, transform: `scale(${scale})`, transformOrigin: 'top left' }}>
            <IOSDevice width={402} height={874} dark={true}>
              <div style={{ position: 'absolute', inset: 0 }}>
                <Carousel key={windowKey} treatment={treatment} idx={idx} go={go} captureRef={captureRef} instant={capturing} />
              </div>
            </IOSDevice>
          </div>
        </div>

        {showNavigationHint && <NavigationHint />}
      </div>

      {/* Controls — OUTSIDE the iPhone frame entirely, in the page chrome.
          Prev / Share / Export / Next. Share captures the CURRENT card and
          opens a native share sheet when available; Export saves a PNG. */}
      {!nativePreview && (
        <div style={{
          zIndex: 6,
          display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 10,
          flexWrap: 'wrap',
        }}>
          <ChromeBtn disabled={idx === 0 || capturing} onClick={() => go(idx - 1)} aria="Previous card">‹</ChromeBtn>
          <button
            onClick={handleShare}
            disabled={currentBusy}
            style={{
              height: 44, padding: '0 22px', borderRadius: 9999, border: 'none',
              background: '#fff', color: '#111',
              fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
              fontSize: 12, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
              cursor: currentBusy ? 'default' : 'pointer',
              boxShadow: '0 6px 20px rgba(0,0,0,0.35)',
            }}>
            {shareState === 'working' ? 'Rendering…'
              : shareState === 'shared' ? '✓ Shared'
              : shareState === 'saved' ? '✓ Saved PNG'
              : shareState === 'failed' ? 'Share failed'
              : 'Share this card'}
          </button>
          <button
            onClick={handleExport}
            disabled={currentBusy}
            style={{
              height: 44, padding: '0 18px', borderRadius: 9999,
              border: '1px solid rgba(255,255,255,0.25)', background: 'rgba(255,255,255,0.08)',
              color: '#fff', backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
              fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
              fontSize: 12, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
              cursor: currentBusy ? 'default' : 'pointer',
            }}>
            {exportState === 'working' ? 'Rendering…'
              : exportState === 'saved' ? '✓ Exported'
              : exportState === 'failed' ? 'Export failed'
              : 'Export PNG'}
          </button>
          <ChromeBtn disabled={idx === CARDS.length - 1 || capturing} onClick={() => go(idx + 1)} aria="Next card">›</ChromeBtn>
        </div>
      )}

      {/* On the final card: share the WHOLE set as one composite image. Still in
          the page chrome, off the creative. */}
      {!nativePreview && idx === CARDS.length - 1 && (
        <div style={{ zIndex: 6, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, flexWrap: 'wrap' }}>
          <button
            onClick={handleShareAll}
            disabled={capturing}
            style={{
              height: 40, padding: '0 20px', borderRadius: 9999,
              border: '1px solid rgba(255,255,255,0.25)', background: 'rgba(255,255,255,0.08)',
              color: '#fff', backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
              fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
              fontSize: 11.5, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
              cursor: capturing ? 'default' : 'pointer',
            }}>
            {shareAllState === 'done' ? '✓ Shared all cards'
              : shareAllState === 'saved' ? '✓ Saved all cards'
              : shareAllState === 'failed' ? 'Share failed'
              : shareAllState ? `Rendering ${shareAllState}…`
              : '⧉ Share all cards'}
          </button>
          <button
            onClick={handleExportAll}
            disabled={capturing}
            style={{
              height: 40, padding: '0 20px', borderRadius: 9999,
              border: '1px solid rgba(255,255,255,0.25)', background: 'rgba(255,255,255,0.08)',
              color: '#fff', backdropFilter: 'blur(8px)', WebkitBackdropFilter: 'blur(8px)',
              fontFamily: 'ui-monospace, "JetBrains Mono", monospace',
              fontSize: 11.5, fontWeight: 600, letterSpacing: '0.12em', textTransform: 'uppercase',
              cursor: capturing ? 'default' : 'pointer',
            }}>
            {exportAllState === 'done' ? '✓ Exported all cards'
              : exportAllState === 'failed' ? 'Export failed'
              : exportAllState ? `Rendering ${exportAllState}…`
              : 'Export all cards'}
          </button>
        </div>
      )}

    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
