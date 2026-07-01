// Premium subscription endpoints for Messages for AI.
//
// One module, four routes (Vercel rewrites in vercel.json):
//   POST /api/premium/checkout     -> Stripe Checkout (subscription mode)
//   POST /api/premium/portal       -> Stripe billing portal
//   GET  /api/premium/entitlement  -> entitlement JSON for the Mac app
//   POST /api/premium/webhook      -> Stripe webhook -> Clerk user metadata
//
// Identity is a Clerk user (consumer app, no organizations). The Stripe
// customer id + subscription state live in the Clerk user's privateMetadata,
// so no extra database is needed:
//   privateMetadata: { stripeCustomerId, premiumActive, stripeSubscriptionId,
//                      currentPeriodEnd }
//
// Required environment variables:
//   CLERK_SECRET_KEY, STRIPE_SECRET_KEY, STRIPE_PREMIUM_PRICE_ID,
//   STRIPE_PREMIUM_WEBHOOK_SECRET, PREMIUM_SITE_URL (https://messagesfor.ai)

const Stripe = require("stripe");
const { createClerkClient, verifyToken } = require("@clerk/backend");

const stripeClient = process.env.STRIPE_SECRET_KEY
  ? new Stripe(process.env.STRIPE_SECRET_KEY)
  : null;

const clerk = process.env.CLERK_SECRET_KEY
  ? createClerkClient({ secretKey: process.env.CLERK_SECRET_KEY })
  : null;

const SITE_URL = (process.env.PREMIUM_SITE_URL || "https://messagesfor.ai").replace(/\/$/, "");
// Entitlement files re-verify within the grace horizon even if the app stays
// offline; period end + 3 days keeps a lapsed card from unlocking for long.
const GRACE_DAYS = 3;

async function requireUser(req) {
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token || !clerk) return null;
  try {
    const claims = await verifyToken(token, { secretKey: process.env.CLERK_SECRET_KEY });
    if (!claims.sub) return null;
    const user = await clerk.users.getUser(claims.sub);
    return user;
  } catch {
    return null;
  }
}

function primaryEmail(user) {
  const primary = user.emailAddresses.find((e) => e.id === user.primaryEmailAddressId);
  return (primary || user.emailAddresses[0])?.emailAddress || null;
}

async function ensureStripeCustomer(user) {
  const existing = user.privateMetadata?.stripeCustomerId;
  if (existing) return existing;
  const customer = await stripeClient.customers.create({
    email: primaryEmail(user) || undefined,
    metadata: { clerkUserId: user.id },
  });
  await clerk.users.updateUserMetadata(user.id, {
    privateMetadata: { stripeCustomerId: customer.id },
  });
  return customer.id;
}

async function handleCheckout(req, res) {
  const user = await requireUser(req);
  if (!user) return res.status(401).json({ error: "Sign in first." });
  if (!process.env.STRIPE_PREMIUM_PRICE_ID) {
    return res.status(503).json({ error: "Premium is not configured yet." });
  }
  const customerId = await ensureStripeCustomer(user);
  const session = await stripeClient.checkout.sessions.create({
    customer: customerId,
    mode: "subscription",
    line_items: [{ price: process.env.STRIPE_PREMIUM_PRICE_ID, quantity: 1 }],
    allow_promotion_codes: true,
    success_url: `${SITE_URL}/account.html?upgraded=1`,
    cancel_url: `${SITE_URL}/account.html?canceled=1`,
    metadata: { clerkUserId: user.id },
  });
  res.status(200).json({ url: session.url });
}

async function handlePortal(req, res) {
  const user = await requireUser(req);
  if (!user) return res.status(401).json({ error: "Sign in first." });
  const customerId = user.privateMetadata?.stripeCustomerId;
  if (!customerId) return res.status(400).json({ error: "No subscription on this account." });
  const session = await stripeClient.billingPortal.sessions.create({
    customer: customerId,
    return_url: `${SITE_URL}/account.html`,
  });
  res.status(200).json({ url: session.url });
}

async function handleEntitlement(req, res) {
  const user = await requireUser(req);
  if (!user) return res.status(401).json({ error: "Sign in first." });
  const meta = user.privateMetadata || {};
  const periodEnd = meta.currentPeriodEnd ? new Date(meta.currentPeriodEnd) : null;
  const expires = periodEnd
    ? new Date(periodEnd.getTime() + GRACE_DAYS * 86400_000)
    : new Date(Date.now() + GRACE_DAYS * 86400_000);
  // Matches the Mac app's Entitlement Codable contract exactly.
  res.status(200).json({
    schema_version: 1,
    subscription_active: meta.premiumActive === true,
    plan: meta.premiumActive === true ? "premium" : null,
    account_email: primaryEmail(user),
    expires_at: expires.toISOString(),
    token: null,
  });
}

async function applySubscriptionState(clerkUserId, active, subscriptionId, periodEndUnix) {
  await clerk.users.updateUserMetadata(clerkUserId, {
    privateMetadata: {
      premiumActive: active,
      stripeSubscriptionId: active ? subscriptionId : null,
      currentPeriodEnd: periodEndUnix ? new Date(periodEndUnix * 1000).toISOString() : null,
    },
  });
}

async function clerkUserIdForCustomer(customerId) {
  const customer = await stripeClient.customers.retrieve(customerId);
  return customer && !customer.deleted ? customer.metadata?.clerkUserId : null;
}

async function handleWebhook(req, res) {
  const signature = req.headers["stripe-signature"];
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  let event;
  try {
    event = stripeClient.webhooks.constructEvent(
      body,
      signature,
      process.env.STRIPE_PREMIUM_WEBHOOK_SECRET
    );
  } catch (error) {
    return res.status(400).json({ error: `Webhook signature failed: ${error.message}` });
  }

  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object;
      const clerkUserId = session.metadata?.clerkUserId;
      if (clerkUserId && session.subscription) {
        const sub = await stripeClient.subscriptions.retrieve(session.subscription);
        await applySubscriptionState(clerkUserId, true, sub.id, sub.current_period_end);
      }
      break;
    }
    case "customer.subscription.updated": {
      const sub = event.data.object;
      const clerkUserId = await clerkUserIdForCustomer(sub.customer);
      if (clerkUserId) {
        const active = ["active", "trialing", "past_due"].includes(sub.status);
        await applySubscriptionState(clerkUserId, active, sub.id, sub.current_period_end);
      }
      break;
    }
    case "customer.subscription.deleted": {
      const sub = event.data.object;
      const clerkUserId = await clerkUserIdForCustomer(sub.customer);
      if (clerkUserId) {
        await applySubscriptionState(clerkUserId, false, null, null);
      }
      break;
    }
    default:
      break;
  }
  res.status(200).json({ received: true });
}

module.exports = async function handler(req, res) {
  if (!stripeClient || !clerk) {
    res.status(503).json({ error: "Premium backend is not configured." });
    return;
  }
  const action = (req.query.action || "").toString();
  try {
    if (req.method === "GET" && action === "config") {
      res.status(200).json({ clerkPublishableKey: process.env.CLERK_PUBLISHABLE_KEY || null });
      return;
    }
    if (req.method === "POST" && action === "checkout") return await handleCheckout(req, res);
    if (req.method === "POST" && action === "portal") return await handlePortal(req, res);
    if (req.method === "GET" && action === "entitlement") return await handleEntitlement(req, res);
    if (req.method === "POST" && action === "webhook") return await handleWebhook(req, res);
    res.status(404).json({ error: "Unknown premium action." });
  } catch (error) {
    res.status(500).json({ error: error.message || "Premium request failed." });
  }
};

// Stripe webhooks need the raw body for signature verification.
module.exports.config = { api: { bodyParser: false } };
