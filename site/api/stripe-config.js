module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const publishableKey =
    process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ||
    process.env.STRIPE_PUBLISHABLE_KEY;
  if (!publishableKey) {
    res.status(503).json({ error: "Stripe is not configured." });
    return;
  }

  res.status(200).json({ publishableKey });
};
