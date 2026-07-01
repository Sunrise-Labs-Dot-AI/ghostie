// Referral program endpoints for Messages for AI.
//
// One module, four actions (query-routed like premium.js):
//   GET  /api/referral?action=config  -> { live, grants } (503 while dark)
//   GET  /api/referral?action=code    -> get-or-create the caller's referral code
//   POST /api/referral?action=redeem  -> referee submits a code post-signup
//   GET  /api/referral?action=stats   -> caller's referral count + credits earned
//
// DARK BY DEFAULT: every action (config included) 503s until
// REFERRAL_PROGRAM_LIVE=true AND Clerk is configured — same gating philosophy
// as premium.js. account.html hides the referral card on any non-200 config.
//
// State is Clerk user metadata only (no extra database):
//   publicMetadata.referralCode   shareable 8-char Crockford-base32 code
//   privateMetadata.referredBy    referee -> referrer user id (one redemption, ever)
//   privateMetadata.referrals[]   referrer audit ledger:
//                                 { refereeId, redeemedAt, credits,
//                                   convertedAt?, conversionCredits? }
//   privateMetadata.credits       the SAME { balance, period } rail that
//                                 ai-proxy.js meters — grants are spendable.
//

const crypto = require("crypto");
const { createClerkClient, verifyToken: clerkVerifyToken } = require("@clerk/backend");

const defaultClerk = process.env.CLERK_SECRET_KEY
  ? createClerkClient({ secretKey: process.env.CLERK_SECRET_KEY })
  : null;

// Grant sizes are the contract with Addendum 3 — change there first.
const GRANTS = {
  refereeSignup: 15, // on top of ai-proxy's standard seed
  referrerSignup: 25, // per redeemed code
  referrerConversion: 100, // when the referee converts to paid (webhook hook)
  maxReferrals: 10, // credited referrals per account; bounds both grant types
};

// Crockford base32 (no I/L/O/U) so codes survive being read aloud or
// hand-typed. 32^8 ≈ 1.1e12 — collisions are ignorable at this scale.
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_LENGTH = 8;

function generateReferralCode() {
  const bytes = crypto.randomBytes(CODE_LENGTH);
  let code = "";
  for (let i = 0; i < CODE_LENGTH; i++) code += CODE_ALPHABET[bytes[i] % 32];
  return code;
}

// Crockford decode aliases: users type what they see (o->0, i/l->1).
function normalizeCode(value) {
  if (typeof value !== "string") return "";
  return value
    .toUpperCase()
    .replace(/[\s-]/g, "")
    .replace(/O/g, "0")
    .replace(/[IL]/g, "1");
}

function isValidCode(code) {
  return (
    typeof code === "string" &&
    code.length === CODE_LENGTH &&
    [...code].every((c) => CODE_ALPHABET.includes(c))
  );
}

// --- Credit rail (mirrors ai-proxy.js — keep in lockstep, or grants will
// double-seed free accounts or clobber the premium monthly refill) ---

const SEED_CREDITS = 25;
const PREMIUM_MONTHLY_CREDITS = 300;

function currentPeriod() {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

function resolveCredits(meta, premium) {
  const stored = meta.credits || {};
  if (premium) {
    if (stored.period === currentPeriod() && typeof stored.balance === "number") return stored;
    return { balance: PREMIUM_MONTHLY_CREDITS, period: currentPeriod() };
  }
  if (typeof stored.balance === "number") return { balance: stored.balance, period: stored.period || null };
  return { balance: SEED_CREDITS, period: null };
}

// Grants ride the resolved balance and keep the period: a premium account's
// bonus lasts until the next monthly refill (accepted in Addendum 3).
function applyGrant(credits, amount) {
  return { balance: credits.balance + amount, period: credits.period ?? null };
}

function referralsOf(meta) {
  return Array.isArray(meta?.referrals) ? meta.referrals : [];
}

// Pure verdict so the cap/self/duplicate rules are unit-testable without HTTP.
function validateRedemption({ refereeId, refereeMeta, referrer }) {
  if (refereeMeta?.referredBy) {
    return { ok: false, status: 409, code: "already_redeemed", message: "This account already redeemed a referral code." };
  }
  if (!referrer) {
    return { ok: false, status: 404, code: "code_not_found", message: "That referral code doesn't exist." };
  }
  if (referrer.id === refereeId) {
    return { ok: false, status: 400, code: "self_referral", message: "You can't redeem your own code." };
  }
  if (referralsOf(referrer.privateMetadata).length >= GRANTS.maxReferrals) {
    return { ok: false, status: 409, code: "referrer_capped", message: "This code has reached its referral limit." };
  }
  return { ok: true };
}

// --- Clerk plumbing ---

async function requireUser(req, { clerk, verifyToken, env }) {
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) return null;
  try {
    const claims = await verifyToken(token, { secretKey: env.CLERK_SECRET_KEY });
    if (!claims.sub) return null;
    return await clerk.users.getUser(claims.sub);
  } catch {
    return null;
  }
}

// Clerk's API can't query metadata, so code lookup is a paged scan. Fine
// below ~10k users; swap in a KV code->userId index before that's real.
async function findUserByReferralCode(clerk, code) {
  const pageSize = 500;
  for (let offset = 0; offset < 10_000; offset += pageSize) {
    const page = await clerk.users.getUserList({ limit: pageSize, offset });
    const users = Array.isArray(page) ? page : page.data || [];
    for (const user of users) {
      if ((user.publicMetadata?.referralCode || "") === code) return user;
    }
    if (users.length < pageSize) break;
  }
  return null;
}

function getBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body !== "string") return {};
  try {
    return JSON.parse(req.body);
  } catch {
    return {};
  }
}

// --- Actions ---

async function handleCode(req, res, deps) {
  const user = await requireUser(req, deps);
  if (!user) return res.status(401).json({ error: "Sign in first." });
  let code = user.publicMetadata?.referralCode;
  if (!isValidCode(code)) {
    code = generateReferralCode();
    await deps.clerk.users.updateUserMetadata(user.id, {
      publicMetadata: { referralCode: code },
    });
  }
  const siteUrl = (deps.env.PREMIUM_SITE_URL || "https://messagesfor.ai").replace(/\/$/, "");
  res.status(200).json({ code, shareUrl: `${siteUrl}/account.html?ref=${code}` });
}

async function handleRedeem(req, res, deps) {
  const referee = await requireUser(req, deps);
  if (!referee) return res.status(401).json({ error: "Sign in first." });
  const code = normalizeCode(getBody(req).code);
  if (!isValidCode(code)) {
    return res.status(400).json({ error: "That doesn't look like a referral code." });
  }

  const refereeMeta = referee.privateMetadata || {};
  const referrer = await findUserByReferralCode(deps.clerk, code);
  const verdict = validateRedemption({ refereeId: referee.id, refereeMeta, referrer });
  if (!verdict.ok) {
    return res.status(verdict.status).json({ error: verdict.message, code: verdict.code });
  }

  const redeemedAt = new Date().toISOString();
  // Referee first: once referredBy is set, a re-submit dies in
  // validateRedemption before the referrer can ever be credited twice.
  const refereeCredits = applyGrant(
    resolveCredits(refereeMeta, refereeMeta.premiumActive === true),
    GRANTS.refereeSignup
  );
  await deps.clerk.users.updateUserMetadata(referee.id, {
    privateMetadata: { credits: refereeCredits, referredBy: referrer.id, referredAt: redeemedAt },
  });

  const referrerMeta = referrer.privateMetadata || {};
  const referrerCredits = applyGrant(
    resolveCredits(referrerMeta, referrerMeta.premiumActive === true),
    GRANTS.referrerSignup
  );
  const referrals = [
    ...referralsOf(referrerMeta),
    { refereeId: referee.id, redeemedAt, credits: GRANTS.referrerSignup },
  ];
  await deps.clerk.users.updateUserMetadata(referrer.id, {
    privateMetadata: { credits: referrerCredits, referrals },
  });

  res.status(200).json({
    granted: GRANTS.refereeSignup,
    referrerGranted: GRANTS.referrerSignup,
    balance: refereeCredits.balance,
  });
}

async function handleStats(req, res, deps) {
  const user = await requireUser(req, deps);
  if (!user) return res.status(401).json({ error: "Sign in first." });
  const meta = user.privateMetadata || {};
  const referrals = referralsOf(meta);
  const creditsEarned = referrals.reduce(
    (sum, entry) => sum + (entry.credits || 0) + (entry.conversionCredits || 0),
    0
  );
  res.status(200).json({
    code: user.publicMetadata?.referralCode || null,
    referrals: referrals.length,
    creditsEarned,
    capRemaining: Math.max(0, GRANTS.maxReferrals - referrals.length),
    redeemed: !!meta.referredBy,
  });
}

// Flip-day hook for premium.js's checkout.session.completed branch.
// Idempotent per referee: the bonus is
// keyed on the referrer's audit entry, and entries only exist for capped,
// validated redemptions — so the 10-referral cap bounds this grant too.
async function recordConversion(clerk, refereeUserId) {
  const referee = await clerk.users.getUser(refereeUserId);
  const referrerId = referee.privateMetadata?.referredBy;
  if (!referrerId) return { granted: false, reason: "not_referred" };
  const referrer = await clerk.users.getUser(referrerId);
  const meta = referrer.privateMetadata || {};
  const referrals = referralsOf(meta);
  const index = referrals.findIndex((entry) => entry.refereeId === refereeUserId);
  if (index === -1) return { granted: false, reason: "no_audit_entry" };
  if (referrals[index].convertedAt) return { granted: false, reason: "already_granted" };
  const updated = referrals.map((entry, i) =>
    i === index
      ? { ...entry, convertedAt: new Date().toISOString(), conversionCredits: GRANTS.referrerConversion }
      : entry
  );
  const credits = applyGrant(
    resolveCredits(meta, meta.premiumActive === true),
    GRANTS.referrerConversion
  );
  await clerk.users.updateUserMetadata(referrerId, {
    privateMetadata: { credits, referrals: updated },
  });
  return { granted: true, credits: GRANTS.referrerConversion };
}

function createHandler({ clerk = defaultClerk, verifyToken = clerkVerifyToken, env = process.env } = {}) {
  const deps = { clerk, verifyToken, env };
  return async function handler(req, res) {
    // Dark until flip-day: config 503s too — account.html reads any non-200
    // config as "hidden", consistent with its accounts-not-live state.
    if (env.REFERRAL_PROGRAM_LIVE !== "true" || !clerk) {
      return res.status(503).json({ live: false, error: "The referral program isn't live yet." });
    }
    const action = ((req.query || {}).action || "").toString();
    try {
      if (req.method === "GET" && action === "config") {
        return res.status(200).json({ live: true, grants: GRANTS });
      }
      if (req.method === "GET" && action === "code") return await handleCode(req, res, deps);
      if (req.method === "POST" && action === "redeem") return await handleRedeem(req, res, deps);
      if (req.method === "GET" && action === "stats") return await handleStats(req, res, deps);
      res.status(404).json({ error: "Unknown referral action." });
    } catch (error) {
      res.status(500).json({ error: error.message || "Referral request failed." });
    }
  };
}

module.exports = createHandler();
module.exports.createHandler = createHandler;
module.exports.recordConversion = recordConversion;
module.exports._internals = {
  GRANTS,
  CODE_ALPHABET,
  CODE_LENGTH,
  generateReferralCode,
  normalizeCode,
  isValidCode,
  currentPeriod,
  resolveCredits,
  applyGrant,
  referralsOf,
  validateRedemption,
};
