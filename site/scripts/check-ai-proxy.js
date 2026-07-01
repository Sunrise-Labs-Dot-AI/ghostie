#!/usr/bin/env node

// Unit checks for the freemium AI proxy's credit metering — the arithmetic
// that decides whether a house-key call runs and what it burns. Same DI
// harness as check-referral.js: fake Clerk, fake fetch, no network.

const test = require("node:test");
const assert = require("node:assert/strict");

const { createHandler, _internals } = require("../api/ai-proxy.js");
const {
  TOOLS,
  SEED_CREDITS,
  PREMIUM_MONTHLY_CREDITS,
  MAX_PROMPT_CHARS,
  currentPeriod,
  resolveCredits,
} = _internals;

const ENV = {
  CLERK_SECRET_KEY: "sk_test_unit",
  ANTHROPIC_HOUSE_KEY: "sk-ant-test-unit",
};

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
        },
      };
    },
  };
}

function fakeClerk(usersById) {
  return {
    users: {
      async getUser(id) {
        const user = usersById.get(id);
        if (!user) throw new Error(`no user ${id}`);
        return user;
      },
      async updateUserMetadata(id, { privateMetadata }) {
        const user = usersById.get(id);
        if (privateMetadata) {
          user.privateMetadata = { ...user.privateMetadata, ...privateMetadata };
        }
        return user;
      },
    },
  };
}

function makeUser(id, privateMetadata = {}) {
  return { id, publicMetadata: {}, privateMetadata };
}

// Anthropic-shaped success unless overridden. Records every request so the
// tests can assert what the server actually sends upstream.
function fakeFetch({ ok = true, status = 200, content } = {}) {
  const calls = [];
  const impl = async (url, options) => {
    calls.push({ url, options, body: JSON.parse(options.body) });
    return {
      ok,
      status,
      json: async () => ({
        content: content ?? [{ type: "text", text: "house model says hi" }],
        usage: { input_tokens: 10, output_tokens: 20 },
      }),
      text: async () => JSON.stringify({ error: { message: "upstream sad" } }),
    };
  };
  impl.calls = calls;
  return impl;
}

function proxyHandler(usersById, { fetchImpl = fakeFetch(), env = ENV } = {}) {
  const handler = createHandler({
    clerk: fakeClerk(usersById),
    verifyToken: async (token) => ({ sub: token }),
    env,
    fetchImpl,
  });
  return { handler, fetchImpl };
}

async function invoke(handler, { method = "POST", token, body } = {}) {
  const res = makeResponse();
  await handler(
    {
      method,
      headers: token ? { authorization: `Bearer ${token}` } : {},
      body,
    },
    res
  );
  return res;
}

const PROMPT = { tool: "dontGhost", prompt: "scan my threads" };

test("resolveCredits: seed, retention, and the premium monthly refill", () => {
  // Fresh free account: seeded once, no period.
  assert.deepEqual(resolveCredits({}, false), { balance: SEED_CREDITS, period: null });
  // Free account keeps whatever it has — including zero (no re-seed exploit).
  assert.deepEqual(resolveCredits({ credits: { balance: 0, period: null } }, false), {
    balance: 0,
    period: null,
  });
  // Premium with no stored credits (upgrade day): full allowance, stamped.
  assert.deepEqual(resolveCredits({}, true), {
    balance: PREMIUM_MONTHLY_CREDITS,
    period: currentPeriod(),
  });
  // Premium mid-period: stored balance stands — no refill until the month turns.
  assert.deepEqual(resolveCredits({ credits: { balance: 7, period: currentPeriod() } }, true), {
    balance: 7,
    period: currentPeriod(),
  });
  // Premium with a stale period: the rollover refill.
  assert.deepEqual(resolveCredits({ credits: { balance: 2, period: "2020-01" } }, true), {
    balance: PREMIUM_MONTHLY_CREDITS,
    period: currentPeriod(),
  });
  // Upgrade mid-month from free (period null counts as stale): refill, not
  // the leftover trial balance.
  assert.deepEqual(resolveCredits({ credits: { balance: 1, period: null } }, true), {
    balance: PREMIUM_MONTHLY_CREDITS,
    period: currentPeriod(),
  });
});

test("premium period rollover refills BEFORE the meter gate", async () => {
  // The edge that matters: last month's balance is below the tool cost. The
  // user must not see 402 — the new month's allowance applies first, and the
  // persisted balance is refill minus this call.
  const users = new Map([
    ["user_p", makeUser("user_p", {
      premiumActive: true,
      credits: { balance: 2, period: "2020-01" },
    })],
  ]);
  const { handler, fetchImpl } = proxyHandler(users);

  const res = await invoke(handler, { token: "user_p", body: { tool: "eq", prompt: "read me" } });

  assert.equal(res.statusCode, 200);
  assert.equal(fetchImpl.calls.length, 1);
  assert.equal(res.body.remaining, PREMIUM_MONTHLY_CREDITS - TOOLS.eq.credits);
  assert.deepEqual(users.get("user_p").privateMetadata.credits, {
    balance: PREMIUM_MONTHLY_CREDITS - TOOLS.eq.credits,
    period: currentPeriod(),
  });
});

test("premium exhausted mid-period is 402 with no sneaky refill", async () => {
  const users = new Map([
    ["user_p", makeUser("user_p", {
      premiumActive: true,
      credits: { balance: TOOLS.eq.credits - 1, period: currentPeriod() },
    })],
  ]);
  const { handler, fetchImpl } = proxyHandler(users);

  const res = await invoke(handler, { token: "user_p", body: { tool: "eq", prompt: "read me" } });

  assert.equal(res.statusCode, 402);
  assert.equal(res.body.error, "monthly_credits_exhausted");
  assert.equal(res.body.remaining, TOOLS.eq.credits - 1);
  assert.equal(fetchImpl.calls.length, 0, "no upstream call on a 402");
  // Balance untouched — the 402 path never writes.
  assert.equal(users.get("user_p").privateMetadata.credits.balance, TOOLS.eq.credits - 1);
});

test("free exhaustion is 402 free_calls_exhausted", async () => {
  const users = new Map([
    ["user_f", makeUser("user_f", { credits: { balance: 0, period: null } })],
  ]);
  const { handler, fetchImpl } = proxyHandler(users);

  const res = await invoke(handler, { token: "user_f", body: PROMPT });

  assert.equal(res.statusCode, 402);
  assert.equal(res.body.error, "free_calls_exhausted");
  assert.equal(fetchImpl.calls.length, 0);
});

test("a successful call burns exactly the tool's credit cost", async () => {
  const users = new Map([["user_f", makeUser("user_f")]]);
  const { handler } = proxyHandler(users);

  const res = await invoke(handler, { token: "user_f", body: PROMPT });

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.text, "house model says hi");
  assert.equal(res.body.remaining, SEED_CREDITS - TOOLS.dontGhost.credits);
  assert.deepEqual(users.get("user_f").privateMetadata.credits, {
    balance: SEED_CREDITS - TOOLS.dontGhost.credits,
    period: null,
  });
});

test("a failed upstream call never burns credits", async () => {
  const users = new Map([
    ["user_f", makeUser("user_f", { credits: { balance: 10, period: null } })],
  ]);
  const { handler } = proxyHandler(users, { fetchImpl: fakeFetch({ ok: false, status: 529 }) });

  const res = await invoke(handler, { token: "user_f", body: PROMPT });

  assert.equal(res.statusCode, 502);
  assert.match(res.body.error, /529/);
  assert.equal(users.get("user_f").privateMetadata.credits.balance, 10, "balance untouched");
});

test("model is fixed server-side and max_tokens clamps to the tool cap", async () => {
  const users = new Map([["user_f", makeUser("user_f")]]);
  const { handler, fetchImpl } = proxyHandler(users);

  await invoke(handler, {
    token: "user_f",
    body: { tool: "eq", prompt: "p", system: "be kind", max_tokens: 999999, model: "claude-opus-9" },
  });

  const sent = fetchImpl.calls[0].body;
  assert.equal(sent.model, TOOLS.eq.model, "client-supplied model is ignored");
  assert.equal(sent.max_tokens, TOOLS.eq.maxTokens, "cap clamps oversize requests");
  assert.equal(sent.system, "be kind");
  assert.deepEqual(sent.messages, [{ role: "user", content: "p" }]);
  assert.equal(fetchImpl.calls[0].options.headers["x-api-key"], ENV.ANTHROPIC_HOUSE_KEY);
});

test("request validation: method, auth, tool, and prompt gates", async () => {
  const users = new Map([["user_f", makeUser("user_f")]]);
  const { handler, fetchImpl } = proxyHandler(users);

  const wrongMethod = await invoke(handler, { method: "GET", token: "user_f", body: PROMPT });
  assert.equal(wrongMethod.statusCode, 405);

  const noToken = await invoke(handler, { body: PROMPT });
  assert.equal(noToken.statusCode, 401);

  const badTool = await invoke(handler, { token: "user_f", body: { tool: "nope", prompt: "p" } });
  assert.equal(badTool.statusCode, 400);

  const emptyPrompt = await invoke(handler, { token: "user_f", body: { tool: "eq", prompt: "   " } });
  assert.equal(emptyPrompt.statusCode, 400);

  const oversize = await invoke(handler, {
    token: "user_f",
    body: { tool: "eq", prompt: "x".repeat(MAX_PROMPT_CHARS + 1) },
  });
  assert.equal(oversize.statusCode, 400);

  assert.equal(fetchImpl.calls.length, 0, "nothing reached the model");

  // Unconfigured deployment fails closed.
  const dark = createHandler({
    clerk: fakeClerk(users),
    verifyToken: async (token) => ({ sub: token }),
    env: { CLERK_SECRET_KEY: "sk" },
    fetchImpl,
  });
  const res = await invoke(dark, { token: "user_f", body: PROMPT });
  assert.equal(res.statusCode, 503);
});

test("credit rail constants stay in lockstep with referral.js", () => {
  const referral = require("../api/referral.js")._internals;
  assert.equal(referral.currentPeriod(), currentPeriod());
  // Same resolution semantics on both rails — a drift here double-seeds
  // free accounts or clobbers the premium refill.
  for (const [meta, premium] of [
    [{}, false],
    [{}, true],
    [{ credits: { balance: 3, period: null } }, false],
    [{ credits: { balance: 120, period: currentPeriod() } }, true],
    [{ credits: { balance: 5, period: "2020-01" } }, true],
  ]) {
    assert.deepEqual(referral.resolveCredits(meta, premium), resolveCredits(meta, premium));
  }
});
