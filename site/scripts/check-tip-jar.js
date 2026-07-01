#!/usr/bin/env node

const test = require("node:test");
const assert = require("node:assert/strict");

process.env.STRIPE_SECRET_KEY = "sk_test_unit";

const { createHandler, _internals } = require("../api/create-tip-session.js");
const stripeConfig = require("../api/stripe-config.js");

function makeResponse() {
  return {
    headers: {},
    statusCode: 200,
    body: undefined,
    setHeader(key, value) {
      this.headers[key.toLowerCase()] = value;
    },
    status(code) {
      this.statusCode = code;
      return {
        json: (body) => {
          this.body = body;
        }
      };
    }
  };
}

async function invoke(handler, req) {
  const res = makeResponse();
  await handler({
    method: "POST",
    headers: {
      origin: "https://messagesfor.ai",
      "x-forwarded-for": "203.0.113.10"
    },
    socket: {},
    body: {
      amount: 867,
      returnPath: "/",
      source: "messages-for-ai"
    },
    ...req
  }, res);
  return res;
}

function fakeStripe() {
  const calls = [];
  return {
    calls,
    checkout: {
      sessions: {
        create: async (payload) => {
          calls.push(payload);
          return { client_secret: "cs_test_secret" };
        }
      }
    }
  };
}

test("creates embedded card-only checkout sessions for allowed origins", async () => {
  const stripe = fakeStripe();
  const handler = createHandler({
    stripe,
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map()
  });

  const res = await invoke(handler, {
    body: {
      amount: 867,
      returnPath: "/thanks",
      source: "messages for ai!"
    }
  });

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { clientSecret: "cs_test_secret" });
  assert.equal(stripe.calls.length, 1);
  assert.equal(stripe.calls[0].ui_mode, "embedded");
  assert.deepEqual(stripe.calls[0].payment_method_types, ["card"]);
  assert.equal(stripe.calls[0].redirect_on_completion, "if_required");
  assert.equal(stripe.calls[0].wallet_options.link.display, "never");
  assert.equal(stripe.calls[0].line_items[0].price_data.product_data.name, "Sunrise Labs Tip Jar");
  assert.equal(stripe.calls[0].line_items[0].price_data.unit_amount, 867);
  assert.equal(stripe.calls[0].metadata.source, "messagesforai");
  assert.equal(stripe.calls[0].metadata.payment_type, "tip_not_donation");
  assert.equal(stripe.calls[0].return_url, "https://messagesfor.ai/thanks?tip_session_id={CHECKOUT_SESSION_ID}");
});

test("rejects disallowed or missing origins before Stripe is called", async () => {
  const stripe = fakeStripe();
  const handler = createHandler({
    stripe,
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map()
  });

  const bad = await invoke(handler, {
    headers: {
      origin: "https://evil.example",
      "x-forwarded-for": "203.0.113.11"
    }
  });
  assert.equal(bad.statusCode, 403);

  const missing = await invoke(handler, {
    headers: {
      "x-forwarded-for": "203.0.113.12"
    }
  });
  assert.equal(missing.statusCode, 403);
  assert.equal(stripe.calls.length, 0);
});

test("rejects unsafe return paths", async () => {
  const stripe = fakeStripe();
  const handler = createHandler({
    stripe,
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map()
  });

  for (const returnPath of ["//evil.example", "/\\evil", "https://evil.example/pay"]) {
    const res = await invoke(handler, { body: { amount: 867, returnPath, source: "test" } });
    assert.equal(res.statusCode, 400);
    assert.match(res.body.error, /Return path/);
  }
  assert.equal(stripe.calls.length, 0);
});

test("enforces amount bounds and method", async () => {
  const handler = createHandler({
    stripe: fakeStripe(),
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map()
  });

  const tooSmall = await invoke(handler, { body: { amount: 99, returnPath: "/", source: "test" } });
  assert.equal(tooSmall.statusCode, 400);

  const tooLarge = await invoke(handler, { body: { amount: 50001, returnPath: "/", source: "test" } });
  assert.equal(tooLarge.statusCode, 400);

  const method = await invoke(handler, { method: "GET" });
  assert.equal(method.statusCode, 405);
  assert.equal(method.headers.allow, "POST");
});

test("rate limits by IP", async () => {
  let now = 1_000;
  const handler = createHandler({
    stripe: fakeStripe(),
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map(),
    now: () => now,
    rateLimit: { windowMs: 60_000, max: 2 }
  });

  const firstHeaders = { origin: "https://messagesfor.ai", "x-forwarded-for": "198.51.100.9" };
  assert.equal((await invoke(handler, { headers: firstHeaders })).statusCode, 200);
  assert.equal((await invoke(handler, { headers: firstHeaders })).statusCode, 200);

  const limited = await invoke(handler, { headers: firstHeaders });
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.headers["retry-after"], "60");

  now += 60_000;
  assert.equal((await invoke(handler, { headers: firstHeaders })).statusCode, 200);
});

test("reports missing Stripe configuration", async () => {
  const handler = createHandler({
    stripe: null,
    allowedOrigins: ["https://messagesfor.ai"],
    store: new Map()
  });

  const res = await invoke(handler);
  assert.equal(res.statusCode, 503);
});

test("stripe-config exposes only the publishable key", async () => {
  process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY = "pk_test_unit";
  const res = makeResponse();

  await stripeConfig({ method: "GET" }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { publishableKey: "pk_test_unit" });

  const rejected = makeResponse();
  await stripeConfig({ method: "POST" }, rejected);
  assert.equal(rejected.statusCode, 405);
});

test("internals keep redirect and source parsing strict", () => {
  assert.equal(_internals.parseReturnPath("/ok?x=1"), "/ok?x=1");
  assert.equal(_internals.parseReturnPath("/bad\\path"), null);
  assert.equal(_internals.parseReturnPath("//bad.example"), null);
  assert.equal(_internals.parseSource("Texting Wrapped!!!"), "TextingWrapped");
  assert.equal(
    _internals.buildReturnUrl("https://messagesfor.ai", "/thanks?from=tip"),
    "https://messagesfor.ai/thanks?from=tip&tip_session_id={CHECKOUT_SESSION_ID}"
  );
  assert.deepEqual(_internals.getBody({ body: "{\"amount\":867}" }), { amount: 867 });
  assert.deepEqual(_internals.getBody({ body: "nope" }), {});
});
