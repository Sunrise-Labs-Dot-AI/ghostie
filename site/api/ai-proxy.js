// Freemium AI proxy: lets signed-in users try each AI lab a few times on the
// house key before subscribing. BYOK users never touch this endpoint.
//
//   POST /api/ai-proxy   Authorization: Bearer <Clerk session token>
//   body: { tool: "eq"|"dontGhost"|"workPersonal"|"textingStyle",
//           prompt: string, system?: string, max_tokens?: number }
//   → { text, remaining } | 402 { error: "free_calls_exhausted" } | 401/400
//
// Metering lives in Clerk user privateMetadata.credits = { balance, period }
// (the same rail referral.js grants ride). Premium subscribers refill monthly.
// The model per tool is fixed server-side to the eval-selected defaults —
// clients on the house key don't choose models. Env: ANTHROPIC_HOUSE_KEY
// (+ Clerk vars).
//
// Exported as createHandler() so the check script (scripts/check-ai-proxy.js)
// can inject a fake Clerk + fetch — same testing seam as referral.js.

const { createClerkClient, verifyToken: clerkVerifyToken } = require("@clerk/backend");

const defaultClerk = process.env.CLERK_SECRET_KEY
  ? createClerkClient({ secretKey: process.env.CLERK_SECRET_KEY })
  : null;

// Credit-based metering (one credit ~ $0.015 of house model cost): every
// account is seeded with trial credits; premium refills a monthly
// allowance. Credits make the burn ceiling explicit — no unlimited tail.
const SEED_CREDITS = 25;            // ~6 EQ reports or 25 ghost scans
const PREMIUM_MONTHLY_CREDITS = 300; // worst-case house cost ≈ $4.50/mo

// Eval-selected defaults. Credit cost is
// proportional to real model cost. Output caps mirror the BYOK app paths.
const TOOLS = {
  eq: { model: "claude-opus-4-8", maxTokens: 2500, credits: 4 },
  dontGhost: { model: "claude-haiku-4-5", maxTokens: 2500, credits: 1 },
  workPersonal: { model: "claude-haiku-4-5", maxTokens: 4000, credits: 2 },
  textingStyle: { model: "claude-opus-4-8", maxTokens: 3500, credits: 8 },
};

function currentPeriod() {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

// Balance lives in Clerk privateMetadata.credits = { balance, period }.
// Free accounts: seeded once, no refill. Premium: allowance resets each
// calendar month (unused credits don't roll over).
// KEEP IN LOCKSTEP with referral.js's copy — grants ride the same rail.
function resolveCredits(meta, premium) {
  const stored = meta.credits || {};
  if (premium) {
    if (stored.period === currentPeriod() && typeof stored.balance === "number") return stored;
    return { balance: PREMIUM_MONTHLY_CREDITS, period: currentPeriod() };
  }
  if (typeof stored.balance === "number") return { balance: stored.balance, period: stored.period || null };
  return { balance: SEED_CREDITS, period: null };
}

const MAX_PROMPT_CHARS = 120_000;

function createHandler({
  clerk = defaultClerk,
  verifyToken = clerkVerifyToken,
  env = process.env,
  fetchImpl = fetch,
} = {}) {
  return async function handler(req, res) {
    if (req.method !== "POST") {
      res.setHeader("Allow", "POST");
      return res.status(405).json({ error: "Method not allowed" });
    }
    if (!clerk || !env.ANTHROPIC_HOUSE_KEY) {
      return res.status(503).json({ error: "Free trial calls aren't configured yet." });
    }

    const header = req.headers.authorization || "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : null;
    if (!token) return res.status(401).json({ error: "Sign in first." });
    let user;
    try {
      const claims = await verifyToken(token, { secretKey: env.CLERK_SECRET_KEY });
      user = await clerk.users.getUser(claims.sub);
    } catch {
      return res.status(401).json({ error: "Session expired — sign in again." });
    }

    const { tool, prompt, system, max_tokens: maxTokensRaw } = req.body || {};
    const config = TOOLS[tool];
    if (!config) return res.status(400).json({ error: "Unknown tool." });
    if (typeof prompt !== "string" || !prompt.trim() || prompt.length > MAX_PROMPT_CHARS) {
      return res.status(400).json({ error: "Bad prompt." });
    }

    const meta = user.privateMetadata || {};
    const premium = meta.premiumActive === true;
    const credits = resolveCredits(meta, premium);
    if (credits.balance < config.credits) {
      return res.status(402).json({
        error: premium ? "monthly_credits_exhausted" : "free_calls_exhausted",
        message: premium
          ? "This month's included usage is used up — add your own API key for unlimited use, or wait for the monthly refill."
          : "Your trial credits are used up — subscribe to keep going, or add your own API key.",
        remaining: credits.balance,
      });
    }

    const maxTokens = Math.min(Number(maxTokensRaw) || config.maxTokens, config.maxTokens);
    const upstream = await fetchImpl("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": env.ANTHROPIC_HOUSE_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: config.model,
        max_tokens: maxTokens,
        ...(system ? { system } : {}),
        messages: [{ role: "user", content: prompt }],
      }),
    });
    if (!upstream.ok) {
      const detail = await upstream.text().catch(() => "");
      return res.status(502).json({ error: `Model call failed (${upstream.status}).`, detail: detail.slice(0, 300) });
    }
    const data = await upstream.json();
    const text = (data.content || [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");

    // Meter after a successful call only (a failed call shouldn't burn
    // credits). A premium period rollover persists here too — the refilled
    // balance minus this call's cost, stamped with the new period.
    const next = { balance: credits.balance - config.credits, period: credits.period };
    await clerk.users.updateUserMetadata(user.id, { privateMetadata: { credits: next } });

    res.status(200).json({
      text,
      remaining: next.balance,
      usage: data.usage || null,
    });
  };
}

module.exports = createHandler();
module.exports.createHandler = createHandler;
module.exports._internals = {
  TOOLS,
  SEED_CREDITS,
  PREMIUM_MONTHLY_CREDITS,
  MAX_PROMPT_CHARS,
  currentPeriod,
  resolveCredits,
};
