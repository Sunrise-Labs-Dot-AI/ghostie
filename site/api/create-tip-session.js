const Stripe = require("stripe");

const MIN_TIP_CENTS = 100;
const MAX_TIP_CENTS = 50000;
const DEFAULT_PRODUCT_NAME = "Sunrise Labs Tip Jar";
const DEFAULT_ALLOWED_ORIGINS = [
  "https://messagesfor.ai",
  "https://www.messagesfor.ai",
  "https://textingwrapped.com",
  "https://www.textingwrapped.com",
  "https://ghostie.app",
  "https://www.ghostie.app"
];
const DEFAULT_RATE_LIMIT = {
  windowMs: 60 * 1000,
  max: 10
};

const stripeClient = process.env.STRIPE_SECRET_KEY
  ? new Stripe(process.env.STRIPE_SECRET_KEY)
  : null;

const rateLimitStore = new Map();

function getAllowedOrigins() {
  const configured = process.env.SUNRISE_TIP_ALLOWED_ORIGINS;
  if (!configured) return DEFAULT_ALLOWED_ORIGINS;
  return configured
    .split(",")
    .map((origin) => origin.trim().replace(/\/$/, ""))
    .filter(Boolean);
}

function getRequestOrigin(req) {
  const origin = req.headers.origin;
  if (typeof origin !== "string") return null;
  return origin.replace(/\/$/, "");
}

function isAllowedOrigin(origin, allowedOrigins = getAllowedOrigins()) {
  return typeof origin === "string" && allowedOrigins.includes(origin);
}

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    return forwarded.split(",")[0].trim();
  }
  return req.socket?.remoteAddress || "unknown";
}

function checkRateLimit(ip, store = rateLimitStore, now = Date.now(), limit = DEFAULT_RATE_LIMIT) {
  const entry = store.get(ip);
  if (!entry || now >= entry.resetAt) {
    store.set(ip, { count: 1, resetAt: now + limit.windowMs });
    return { allowed: true };
  }

  entry.count += 1;
  if (entry.count > limit.max) {
    return { allowed: false, resetAt: entry.resetAt };
  }
  return { allowed: true };
}

function parseAmount(value) {
  const amount = Number(value);
  if (!Number.isInteger(amount)) return null;
  if (amount < MIN_TIP_CENTS || amount > MAX_TIP_CENTS) return null;
  return amount;
}

function parseReturnPath(value) {
  if (value == null || value === "") return "/";
  if (typeof value !== "string") return null;
  if (!value.startsWith("/") || value.startsWith("//") || value.includes("\\")) return null;
  return value.slice(0, 240);
}

function parseSource(value) {
  if (typeof value !== "string") return "unknown";
  return value.replace(/[^a-z0-9_-]/gi, "").slice(0, 48) || "unknown";
}

function buildReturnUrl(origin, returnPath) {
  const url = new URL(returnPath, origin);
  const separator = url.search ? "&" : "?";
  return `${url.origin}${url.pathname}${url.search}${separator}tip_session_id={CHECKOUT_SESSION_ID}${url.hash}`;
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

function createHandler({
  stripe = stripeClient,
  allowedOrigins = getAllowedOrigins(),
  store = rateLimitStore,
  now = () => Date.now(),
  rateLimit = DEFAULT_RATE_LIMIT
} = {}) {
  return async function handler(req, res) {
    if (req.method !== "POST") {
      res.setHeader("Allow", "POST");
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    const origin = getRequestOrigin(req);
    if (!isAllowedOrigin(origin, allowedOrigins)) {
      res.status(403).json({ error: "Tip jar requests must come from Sunrise Labs sites." });
      return;
    }

    const ip = getClientIp(req);
    const rate = checkRateLimit(ip, store, now(), rateLimit);
    if (!rate.allowed) {
      res.setHeader("Retry-After", String(Math.ceil((rate.resetAt - now()) / 1000)));
      res.status(429).json({ error: "Too many attempts. Please try again in a minute." });
      return;
    }

    if (!stripe) {
      res.status(503).json({ error: "Stripe is not configured." });
      return;
    }

    const body = getBody(req);
    const amount = parseAmount(body.amount);
    if (!amount) {
      res.status(400).json({ error: "Choose an amount from $1 to $500." });
      return;
    }

    const returnPath = parseReturnPath(body.returnPath);
    if (!returnPath) {
      res.status(400).json({ error: "Return path is not allowed." });
      return;
    }

    const source = parseSource(body.source);

    try {
      const session = await stripe.checkout.sessions.create({
        ui_mode: "embedded",
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              currency: "usd",
              product_data: {
                name: process.env.SUNRISE_TIP_PRODUCT_NAME || DEFAULT_PRODUCT_NAME
              },
              unit_amount: amount
            },
            quantity: 1
          }
        ],
        payment_intent_data: {
          description: "Sunrise Labs Tip Jar"
        },
        redirect_on_completion: "if_required",
        wallet_options: {
          link: {
            display: "never"
          }
        },
        metadata: {
          source,
          payment_type: "tip_not_donation"
        },
        return_url: buildReturnUrl(origin, returnPath)
      });

      res.status(200).json({ clientSecret: session.client_secret });
    } catch (error) {
      console.error("Stripe checkout session failed", {
        message: error && error.message,
        type: error && error.type,
        code: error && error.code
      });
      res.status(500).json({ error: "Stripe checkout could not start." });
    }
  };
}

module.exports = createHandler();
module.exports.createHandler = createHandler;
module.exports._internals = {
  DEFAULT_ALLOWED_ORIGINS,
  DEFAULT_RATE_LIMIT,
  checkRateLimit,
  getAllowedOrigins,
  isAllowedOrigin,
  parseAmount,
  buildReturnUrl,
  parseReturnPath,
  parseSource,
  getBody
};
