#!/usr/bin/env node

const test = require("node:test");
const assert = require("node:assert/strict");

const { createHandler, recordConversion, _internals } = require("../api/referral.js");
const {
  GRANTS,
  CODE_ALPHABET,
  CODE_LENGTH,
  generateReferralCode,
  normalizeCode,
  isValidCode,
  currentPeriod,
  resolveCredits,
  applyGrant,
  validateRedemption,
} = _internals;

const LIVE_ENV = {
  REFERRAL_PROGRAM_LIVE: "true",
  CLERK_SECRET_KEY: "sk_test_unit",
  PREMIUM_SITE_URL: "https://messagesfor.ai",
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
        }
      };
    }
  };
}

// Fake Clerk: token === user id (verifyToken stub below), shallow metadata
// merge like the real updateUserMetadata.
function fakeClerk(usersById) {
  return {
    users: {
      async getUser(id) {
        const user = usersById.get(id);
        if (!user) throw new Error(`no user ${id}`);
        return user;
      },
      async getUserList({ limit = 500, offset = 0 } = {}) {
        const all = [...usersById.values()];
        return { data: all.slice(offset, offset + limit), totalCount: all.length };
      },
      async updateUserMetadata(id, { publicMetadata, privateMetadata }) {
        const user = usersById.get(id);
        if (publicMetadata) user.publicMetadata = { ...user.publicMetadata, ...publicMetadata };
        if (privateMetadata) user.privateMetadata = { ...user.privateMetadata, ...privateMetadata };
        return user;
      }
    }
  };
}

function makeUser(id, overrides = {}) {
  return { id, publicMetadata: {}, privateMetadata: {}, ...overrides };
}

function liveHandler(usersById) {
  const clerk = fakeClerk(usersById);
  return createHandler({
    clerk,
    env: LIVE_ENV,
    verifyToken: async (token) => ({ sub: token }),
  });
}

async function invoke(handler, { method = "GET", action, token, body } = {}) {
  const res = makeResponse();
  await handler({
    method,
    query: { action },
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body,
  }, res);
  return res;
}

function referralEntries(count) {
  return Array.from({ length: count }, (_, i) => ({
    refereeId: `user_referee_${i}`,
    redeemedAt: "2026-06-10T00:00:00.000Z",
    credits: GRANTS.referrerSignup,
  }));
}

test("grant constants match Addendum 3 of the economics report", () => {
  assert.equal(GRANTS.refereeSignup, 15);
  assert.equal(GRANTS.referrerSignup, 25);
  assert.equal(GRANTS.referrerConversion, 100);
  assert.equal(GRANTS.maxReferrals, 10);
});

test("codes are 8 chars of unambiguous Crockford base32 and don't collide", () => {
  const seen = new Set();
  for (let i = 0; i < 500; i++) {
    const code = generateReferralCode();
    assert.equal(code.length, CODE_LENGTH);
    for (const ch of code) assert(CODE_ALPHABET.includes(ch), `bad char ${ch}`);
    for (const banned of "ILOU") assert(!code.includes(banned), `ambiguous char ${banned}`);
    assert(isValidCode(code));
    seen.add(code);
  }
  assert.equal(seen.size, 500);
});

test("normalization maps what users actually type", () => {
  assert.equal(normalizeCode(" o0il-23ab "), "001123AB");
  assert(isValidCode(normalizeCode("o0il-23ab")));
  assert.equal(normalizeCode("abcd 2345"), "ABCD2345");
  assert(!isValidCode("SHORT"));
  assert(!isValidCode("ABCDEFGU"));
  assert(!isValidCode(12345678));
  assert(!isValidCode(null));
  assert(isValidCode("ABCD2345"));
});

test("grant arithmetic rides the ai-proxy credit rail", () => {
  // Free account, nothing stored: seed materializes, then the grant lands.
  assert.deepEqual(
    applyGrant(resolveCredits({}, false), GRANTS.refereeSignup),
    { balance: 40, period: null }
  );
  // Free account with a depleted balance keeps it, plus the grant.
  assert.deepEqual(
    applyGrant(resolveCredits({ credits: { balance: 3, period: null } }, false), GRANTS.referrerSignup),
    { balance: 28, period: null }
  );
  // Premium mid-period: grant stacks on the remaining allowance.
  assert.deepEqual(
    applyGrant(
      resolveCredits({ credits: { balance: 120, period: currentPeriod() } }, true),
      GRANTS.referrerConversion
    ),
    { balance: 220, period: currentPeriod() }
  );
  // Premium with a stale period: refill first, then the grant.
  assert.deepEqual(
    applyGrant(resolveCredits({ credits: { balance: 5, period: "2020-01" } }, true), GRANTS.referrerSignup),
    { balance: 325, period: currentPeriod() }
  );
});

test("self-redeem is rejected", () => {
  const verdict = validateRedemption({
    refereeId: "user_a",
    refereeMeta: {},
    referrer: makeUser("user_a"),
  });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.code, "self_referral");
  assert.equal(verdict.status, 400);
});

test("the 10-referral cap blocks the 11th redemption", () => {
  const at9 = validateRedemption({
    refereeId: "user_new",
    refereeMeta: {},
    referrer: makeUser("user_ref", { privateMetadata: { referrals: referralEntries(9) } }),
  });
  assert.equal(at9.ok, true);

  const at10 = validateRedemption({
    refereeId: "user_new",
    refereeMeta: {},
    referrer: makeUser("user_ref", { privateMetadata: { referrals: referralEntries(10) } }),
  });
  assert.equal(at10.ok, false);
  assert.equal(at10.code, "referrer_capped");
  assert.equal(at10.status, 409);
});

test("duplicate redemption and unknown codes are rejected", () => {
  const dup = validateRedemption({
    refereeId: "user_b",
    refereeMeta: { referredBy: "user_x" },
    referrer: makeUser("user_x"),
  });
  assert.equal(dup.code, "already_redeemed");
  assert.equal(dup.status, 409);

  const missing = validateRedemption({ refereeId: "user_b", refereeMeta: {}, referrer: null });
  assert.equal(missing.code, "code_not_found");
  assert.equal(missing.status, 404);
});

test("every action 503s while the program is dark", async () => {
  const darkVariants = [
    // Flag off, Clerk present.
    createHandler({ clerk: fakeClerk(new Map()), env: { CLERK_SECRET_KEY: "sk" } }),
    // Flag on, Clerk missing.
    createHandler({ clerk: null, env: { REFERRAL_PROGRAM_LIVE: "true" } }),
  ];
  const actions = [
    { method: "GET", action: "config" },
    { method: "GET", action: "code" },
    { method: "POST", action: "redeem", body: { code: "ABCD2345" } },
    { method: "GET", action: "stats" },
  ];
  for (const handler of darkVariants) {
    for (const req of actions) {
      const res = await invoke(handler, { ...req, token: "user_any" });
      assert.equal(res.statusCode, 503);
      assert.equal(res.body.live, false);
    }
  }
});

test("code action mints once and then returns the stored code", async () => {
  const users = new Map([["user_a", makeUser("user_a")]]);
  const handler = liveHandler(users);

  const first = await invoke(handler, { action: "code", token: "user_a" });
  assert.equal(first.statusCode, 200);
  assert(isValidCode(first.body.code));
  assert.equal(first.body.shareUrl, `https://messagesfor.ai/account.html?ref=${first.body.code}`);
  assert.equal(users.get("user_a").publicMetadata.referralCode, first.body.code);

  const second = await invoke(handler, { action: "code", token: "user_a" });
  assert.equal(second.body.code, first.body.code);
});

test("redeem grants both sides, writes the audit entry, and won't double-fire", async () => {
  const users = new Map([
    ["user_referrer", makeUser("user_referrer", { publicMetadata: { referralCode: "ABCD2345" } })],
    ["user_referee", makeUser("user_referee")],
  ]);
  const handler = liveHandler(users);

  const res = await invoke(handler, {
    method: "POST", action: "redeem", token: "user_referee", body: { code: "abcd-2345" },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.granted, GRANTS.refereeSignup);
  assert.equal(res.body.referrerGranted, GRANTS.referrerSignup);
  assert.equal(res.body.balance, 40); // 25 seed + 15 bonus

  const referrer = users.get("user_referrer");
  assert.equal(referrer.privateMetadata.credits.balance, 50); // 25 seed + 25 bonus
  assert.equal(referrer.privateMetadata.referrals.length, 1);
  assert.equal(referrer.privateMetadata.referrals[0].refereeId, "user_referee");
  assert.equal(referrer.privateMetadata.referrals[0].credits, GRANTS.referrerSignup);
  assert.equal(users.get("user_referee").privateMetadata.referredBy, "user_referrer");

  const again = await invoke(handler, {
    method: "POST", action: "redeem", token: "user_referee", body: { code: "ABCD2345" },
  });
  assert.equal(again.statusCode, 409);
  assert.equal(again.body.code, "already_redeemed");
  assert.equal(referrer.privateMetadata.referrals.length, 1);
  assert.equal(referrer.privateMetadata.credits.balance, 50);
});

test("redeeming your own code via the handler is rejected", async () => {
  const users = new Map([
    ["user_referrer", makeUser("user_referrer", { publicMetadata: { referralCode: "ABCD2345" } })],
  ]);
  const handler = liveHandler(users);
  const res = await invoke(handler, {
    method: "POST", action: "redeem", token: "user_referrer", body: { code: "ABCD2345" },
  });
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.code, "self_referral");
  assert.equal(users.get("user_referrer").privateMetadata.credits, undefined);
});

test("conversion bonus lands once per referee", async () => {
  const users = new Map([
    ["user_referrer", makeUser("user_referrer", {
      privateMetadata: {
        credits: { balance: 50, period: null },
        referrals: [{ refereeId: "user_referee", redeemedAt: "2026-06-10T00:00:00.000Z", credits: 25 }],
      },
    })],
    ["user_referee", makeUser("user_referee", { privateMetadata: { referredBy: "user_referrer" } })],
  ]);
  const clerk = fakeClerk(users);

  const granted = await recordConversion(clerk, "user_referee");
  assert.equal(granted.granted, true);
  assert.equal(granted.credits, GRANTS.referrerConversion);
  const referrer = users.get("user_referrer");
  assert.equal(referrer.privateMetadata.credits.balance, 150); // 50 + 100
  assert.equal(referrer.privateMetadata.referrals[0].conversionCredits, GRANTS.referrerConversion);
  assert(referrer.privateMetadata.referrals[0].convertedAt);

  const repeat = await recordConversion(clerk, "user_referee");
  assert.equal(repeat.granted, false);
  assert.equal(repeat.reason, "already_granted");
  assert.equal(referrer.privateMetadata.credits.balance, 150);

  const unreferred = await recordConversion(clerk, "user_referrer");
  assert.equal(unreferred.granted, false);
  assert.equal(unreferred.reason, "not_referred");
});

test("stats reports count, earned credits, cap headroom, and redeemed state", async () => {
  const users = new Map([
    ["user_a", makeUser("user_a", {
      publicMetadata: { referralCode: "ABCD2345" },
      privateMetadata: {
        referrals: [
          { refereeId: "u1", redeemedAt: "2026-06-10T00:00:00.000Z", credits: 25 },
          { refereeId: "u2", redeemedAt: "2026-06-10T00:00:00.000Z", credits: 25, conversionCredits: 100, convertedAt: "2026-06-11T00:00:00.000Z" },
        ],
      },
    })],
  ]);
  const handler = liveHandler(users);
  const res = await invoke(handler, { action: "stats", token: "user_a" });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, {
    code: "ABCD2345",
    referrals: 2,
    creditsEarned: 150,
    capRemaining: 8,
    redeemed: false,
  });
});
