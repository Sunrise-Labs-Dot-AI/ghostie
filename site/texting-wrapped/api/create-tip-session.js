const Stripe = require("stripe");

const MIN_TIP_CENTS = 100;
const MAX_TIP_CENTS = 50000;
const DEFAULT_PRODUCT_NAME = "Sunrise Labs Tip Jar";

function getOrigin(req) {
  const configuredOrigin = process.env.SUNRISE_TIP_ORIGIN;
  if (configuredOrigin) return configuredOrigin.replace(/\/$/, "");

  const proto = req.headers["x-forwarded-proto"] || "https";
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  return `${proto}://${host}`;
}

function parseAmount(value) {
  const amount = Number(value);
  if (!Number.isInteger(amount)) return null;
  if (amount < MIN_TIP_CENTS || amount > MAX_TIP_CENTS) return null;
  return amount;
}

function parseReturnPath(value) {
  if (typeof value !== "string" || !value.startsWith("/")) return "/";
  if (value.startsWith("//")) return "/";
  return value.slice(0, 240);
}

function parseSource(value) {
  if (typeof value !== "string") return "unknown";
  return value.replace(/[^a-z0-9_-]/gi, "").slice(0, 48) || "unknown";
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey) {
    res.status(503).json({ error: "Stripe is not configured." });
    return;
  }

  const amount = parseAmount(req.body && req.body.amount);
  if (!amount) {
    res.status(400).json({ error: "Choose an amount from $1 to $500." });
    return;
  }

  const stripe = new Stripe(secretKey);
  const source = parseSource(req.body && req.body.source);
  const origin = getOrigin(req);
  const returnPath = parseReturnPath(req.body && req.body.returnPath);

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
      return_url: `${origin}${returnPath}?tip_session_id={CHECKOUT_SESSION_ID}`
    });

    res.status(200).json({ clientSecret: session.client_secret });
  } catch (error) {
    res.status(500).json({ error: "Stripe checkout could not start." });
  }
};
