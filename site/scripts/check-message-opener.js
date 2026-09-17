#!/usr/bin/env node

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { createHandler, _internals } = require("../api/message-opener.js");

const KEY = Buffer.alloc(32, 7).toString("base64url");
const ENV = {
  BLOB_READ_WRITE_TOKEN: "blob-test-token",
  MESSAGE_OPENER_API_TOKEN: "create-test-token",
  MESSAGE_OPENER_ENCRYPTION_KEY: KEY,
  CRON_SECRET: "cron-test-token",
};
const AUTH = { authorization: `Bearer ${ENV.MESSAGE_OPENER_API_TOKEN}` };
const JSON_HEADERS = { ...AUTH, "content-type": "application/json" };
const FIXED_NOW = Date.UTC(2026, 8, 16, 12, 0, 0);

function deterministicBytes(size) {
  return Buffer.alloc(size, size);
}

function contrastRatio(foreground, background) {
  const luminance = (hex) => {
    const channels = hex
      .match(/[0-9a-f]{2}/gi)
      .map((value) => parseInt(value, 16) / 255)
      .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
  };
  const first = luminance(foreground);
  const second = luminance(background);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

function makeResponse() {
  return {
    headers: {},
    statusCode: 200,
    body: undefined,
    setHeader(name, value) {
      this.headers[name.toLowerCase()] = value;
    },
    end(body) {
      this.body = body;
    },
  };
}

function makeStorage() {
  const records = new Map();
  const calls = { put: 0, get: 0, list: 0, read: 0, delete: [] };
  return {
    records,
    calls,
    async put(pathname, body) {
      calls.put += 1;
      if (records.has(pathname)) throw new Error("collision");
      records.set(pathname, body);
    },
    async get(pathname) {
      calls.get += 1;
      const body = records.get(pathname);
      return body === undefined ? null : { body, pathname, target: pathname };
    },
    async list() {
      calls.list += 1;
      return {
        items: [...records.keys()].map((pathname) => ({ pathname, url: pathname })),
        cursor: undefined,
      };
    },
    async read(item) {
      calls.read += 1;
      return records.get(item.pathname) ?? null;
    },
    async delete(target) {
      calls.delete.push(target);
      records.delete(target);
    },
  };
}

async function invoke(handler, { method = "GET", action, id, headers = {}, body } = {}) {
  const req = { method, query: { action, ...(id ? { id } : {}) }, headers, body };
  const res = makeResponse();
  await handler(req, res);
  return res;
}

async function createLink({
  storage = makeStorage(),
  now = FIXED_NOW,
  phone,
  body,
  randomBytes = deterministicBytes,
} = {}) {
  const handler = createHandler({
    env: ENV,
    storage,
    now: () => now,
    randomBytes,
  });
  const response = await invoke(handler, {
    method: "POST",
    action: "create",
    headers: JSON_HEADERS,
    body: {
      phone: phone ?? "+12155550123",
      body: body ?? "This is a fictional compose-only test.",
    },
  });
  return { handler, response, storage };
}

test("unauthorized creation rejects before reading the request body or touching storage", async () => {
  const storage = makeStorage();
  const handler = createHandler({ env: ENV, storage });
  const req = { method: "POST", query: { action: "create" }, headers: {} };
  Object.defineProperty(req, "body", {
    get() {
      throw new Error("body must not be read");
    },
  });
  const res = makeResponse();

  await handler(req, res);

  assert.equal(res.statusCode, 401);
  assert.equal(storage.calls.put, 0);
});

test("oversize JSON rejects with 413 before body access", async () => {
  const storage = makeStorage();
  const handler = createHandler({ env: ENV, storage });
  const req = {
    method: "POST",
    query: { action: "create" },
    headers: { ...JSON_HEADERS, "content-length": String(_internals.MAX_REQUEST_BYTES + 1) },
  };
  Object.defineProperty(req, "body", {
    get() {
      throw new Error("body must not be read");
    },
  });
  const res = makeResponse();

  await handler(req, res);

  assert.equal(res.statusCode, 413);
  assert.equal(storage.calls.put, 0);
});

test("creation returns a 96-bit public URL and stores ciphertext only", async () => {
  const phone = "+12155550123";
  const body = "A private draft body";
  const randomSizes = [];
  const { response, storage } = await createLink({
    phone,
    body,
    randomBytes(size) {
      randomSizes.push(size);
      return deterministicBytes(size);
    },
  });

  assert.equal(response.statusCode, 201);
  const result = JSON.parse(response.body);
  assert.match(result.url, /^https:\/\/ghostie\.app\/t\/[A-Za-z0-9_-]{16}$/);
  assert.equal(randomSizes[0], 12, "the bearer id uses 12 random bytes");
  assert.equal(result.expires_at, new Date(FIXED_NOW + _internals.LINK_TTL_MS).toISOString());
  assert.equal(response.headers["cache-control"], "private, no-store, max-age=0");

  const [[pathname, stored]] = [...storage.records.entries()];
  assert.match(pathname, /^message-openers\/[A-Za-z0-9_-]{16}\.json$/);
  assert.doesNotMatch(stored, new RegExp(phone.replace("+", "\\+")));
  assert.doesNotMatch(stored, /private draft body/);
  const envelope = JSON.parse(stored);
  const id = pathname.slice(_internals.PREFIX.length, -".json".length);
  const payload = _internals.decryptPayload(envelope, id, _internals.decodeEncryptionKey(KEY));
  assert.equal(payload.phone, phone);
  assert.equal(payload.body, body);
});

test("invalid phone, empty body, and unpaired surrogates are rejected", async () => {
  for (const draft of [
    { phone: "2155550123", body: "hello" },
    { phone: "+12155550123", body: "   " },
    { phone: "+12155550123", body: "bad\ud800text" },
    { phone: "+12155550123", body: "bad\udc00text" },
  ]) {
    const storage = makeStorage();
    const handler = createHandler({ env: ENV, storage, randomBytes: deterministicBytes });
    const response = await invoke(handler, {
      method: "POST",
      action: "create",
      headers: JSON_HEADERS,
      body: draft,
    });
    assert.equal(response.statusCode, 400);
    assert.equal(storage.calls.put, 0);
  }
});

test("body limit counts Unicode scalars rather than UTF-16 code units", async () => {
  const accepted = await createLink({ body: "👻".repeat(_internals.MAX_BODY_CHARS) });
  assert.equal(accepted.response.statusCode, 201);

  const rejected = await createLink({ body: "a".repeat(_internals.MAX_BODY_CHARS + 1) });
  assert.equal(rejected.response.statusCode, 400);
});

test("malformed ids return 404 without a Blob read", async () => {
  const storage = makeStorage();
  const handler = createHandler({ env: ENV, storage });
  const response = await invoke(handler, { action: "open", id: "../../release" });
  assert.equal(response.statusCode, 404);
  assert.equal(storage.calls.get, 0);
});

test("landing page contains the three targets in order without plaintext body", async () => {
  const body = "Hey & <there> \"friend\" 👻";
  const created = await createLink({ body });
  const id = JSON.parse(created.response.body).url.split("/").pop();
  const response = await invoke(created.handler, { action: "open", id });

  assert.equal(response.statusCode, 200);
  assert.match(response.headers["content-type"], /^text\/html/);
  assert.equal(response.headers["referrer-policy"], "no-referrer");
  assert.match(response.headers["content-security-policy"], /default-src 'none'/);
  assert.doesNotMatch(response.body, new RegExp(body.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));

  const targets = _internals.messageTargets("+12155550123", body);
  const serializedTargets = JSON.stringify(targets).replaceAll("&", "\\u0026");
  assert.ok(
    response.body.includes(targets[0].replaceAll("&", "&amp;")),
    "primary target is present in the meta refresh and fallback link"
  );
  assert.ok(
    response.body.includes(`const targets = ${serializedTargets};`),
    "all targets are embedded in the requested order"
  );
  assert.ok(
    response.body.includes(`href="${targets[1].replaceAll("&", "&amp;")}"`) &&
      response.body.includes(`href="${targets[2].replaceAll("&", "&amp;")}"`),
    "alternate targets are available as user-gesture links"
  );
  assert.match(response.body, /location\.replace\(targets\[index\]\)/);
  assert.match(response.body, /setTimeout\(\(\) => open\(1\), 700\)/);
  assert.match(response.body, /setTimeout\(\(\) => open\(2\), 1400\)/);

  const smallColor = response.body.match(/small \{[^}]*color: (#[0-9a-f]{6})/i)?.[1];
  assert.ok(smallColor, "fallback text has an explicit color");
  assert.ok(contrastRatio(smallColor, "#ffffff") >= 4.5, "fallback text meets WCAG AA contrast");
});

test("landing page safely encodes hostile and unusual message text", async () => {
  const body = `</script><script>alert("x&y")</script>\r\nquote ' # ? % 👻 \u202E \u2028 \u2029`;
  const created = await createLink({ body });
  const id = JSON.parse(created.response.body).url.split("/").pop();
  const response = await invoke(created.handler, { action: "open", id });

  assert.equal(response.statusCode, 200);
  assert.match(response.headers["content-security-policy"], /default-src 'none'/);
  assert.doesNotMatch(response.body, /<script>alert/);
  assert.doesNotMatch(response.body, /<\/script><script>/);
  assert.doesNotMatch(response.body, /\u2028|\u2029/);

  const targets = _internals.messageTargets("+12155550123", body);
  const serializedTargets = JSON.stringify(targets)
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
  assert.ok(response.body.includes(`const targets = ${serializedTargets};`));
  assert.ok(targets.every((target) => target.includes(encodeURIComponent(body))));
});

test("tampered ciphertext returns 404 instead of leaking a decrypt error", async () => {
  const created = await createLink();
  const id = JSON.parse(created.response.body).url.split("/").pop();
  const pathname = _internals.openerPath(id);
  const envelope = JSON.parse(created.storage.records.get(pathname));
  const replacement = envelope.ciphertext[0] === "A" ? "B" : "A";
  envelope.ciphertext = `${replacement}${envelope.ciphertext.slice(1)}`;
  created.storage.records.set(pathname, JSON.stringify(envelope));

  const response = await invoke(created.handler, { action: "open", id });
  assert.equal(response.statusCode, 404);
  assert.equal(JSON.parse(response.body).error, "Link not found");
});

test("expired link returns 410 once, deletes, then returns 404", async () => {
  const storage = makeStorage();
  let clock = FIXED_NOW;
  const handler = createHandler({
    env: ENV,
    storage,
    now: () => clock,
    randomBytes: deterministicBytes,
  });
  const created = await invoke(handler, {
    method: "POST",
    action: "create",
    headers: JSON_HEADERS,
    body: { phone: "+12155550123", body: "expires" },
  });
  const id = JSON.parse(created.body).url.split("/").pop();
  clock += _internals.LINK_TTL_MS;

  const first = await invoke(handler, { action: "open", id });
  const second = await invoke(handler, { action: "open", id });
  assert.equal(first.statusCode, 410);
  assert.equal(second.statusCode, 404);
  assert.deepEqual(storage.calls.delete, [_internals.openerPath(id)]);
});

test("an expired link still returns 410 when immediate deletion fails", async () => {
  const storage = makeStorage();
  let clock = FIXED_NOW;
  storage.delete = async () => {
    throw new Error("transient Blob failure");
  };
  const handler = createHandler({
    env: ENV,
    storage,
    now: () => clock,
    randomBytes: deterministicBytes,
  });
  const created = await invoke(handler, {
    method: "POST",
    action: "create",
    headers: JSON_HEADERS,
    body: { phone: "+12155550123", body: "expires" },
  });
  const id = JSON.parse(created.body).url.split("/").pop();
  clock += _internals.LINK_TTL_MS;

  const response = await invoke(handler, { action: "open", id });
  assert.equal(response.statusCode, 410);
});

test("cleanup paginates and deletes only valid expired opener records", async () => {
  const expired = JSON.stringify({ v: 1, expiresAt: FIXED_NOW - 1, iv: "a", tag: "b", ciphertext: "c" });
  const active = JSON.stringify({ v: 1, expiresAt: FIXED_NOW + 1, iv: "a", tag: "b", ciphertext: "c" });
  const values = new Map([
    ["message-openers/expired.json", expired],
    ["message-openers/active.json", active],
    ["message-openers/invalid.json", "{}"],
    ["releases/v0.14.0/Ghostie.dmg", expired],
  ]);
  const deleted = [];
  let pages = 0;
  const storage = {
    async list(cursor) {
      pages += 1;
      if (!cursor) {
        return {
          items: [
            { pathname: "message-openers/expired.json", url: "message-openers/expired.json" },
            { pathname: "releases/v0.14.0/Ghostie.dmg", url: "releases/v0.14.0/Ghostie.dmg" },
          ],
          cursor: "page-2",
        };
      }
      return {
        items: [
          { pathname: "message-openers/active.json", url: "message-openers/active.json" },
          { pathname: "message-openers/invalid.json", url: "message-openers/invalid.json" },
        ],
      };
    },
    async read(item) {
      return values.get(item.pathname);
    },
    async delete(target) {
      deleted.push(target);
    },
  };

  const result = await _internals.cleanupExpired(storage, FIXED_NOW);
  assert.equal(pages, 2);
  assert.deepEqual(result, { deleted: 1, failed: 0 });
  assert.deepEqual(deleted, ["message-openers/expired.json"]);
});

test("cleanup isolates individual read and delete failures", async () => {
  const expired = JSON.stringify({ v: 1, expiresAt: FIXED_NOW - 1, iv: "a", tag: "b", ciphertext: "c" });
  const deleteAttempts = [];
  const storage = {
    async list() {
      return {
        items: [
          { pathname: "message-openers/delete-fails.json", url: "delete-fails" },
          { pathname: "message-openers/read-fails.json", url: "read-fails" },
          { pathname: "message-openers/deletes.json", url: "deletes" },
        ],
      };
    },
    async read(item) {
      if (item.url === "read-fails") throw new Error("transient read failure");
      return expired;
    },
    async delete(target) {
      deleteAttempts.push(target);
      if (target === "delete-fails") throw new Error("transient delete failure");
    },
  };

  const result = await _internals.cleanupExpired(storage, FIXED_NOW);
  assert.deepEqual(result, { deleted: 1, failed: 2 });
  assert.deepEqual(deleteAttempts, ["delete-fails", "deletes"]);
});

test("Blob adapter performs uncached SDK reads and keeps the opener prefix scoped", async () => {
  const calls = [];
  const result = (target, body) => ({
    statusCode: 200,
    stream: new Response(body).body,
    blob: { url: `https://blob.test/${target}`, pathname: target },
  });
  const sdk = {
    async put(pathname, body, options) {
      calls.push(["put", pathname, body, options]);
    },
    async get(target, options) {
      calls.push(["get", target, options]);
      return result(target, `body:${target}`);
    },
    async list(options) {
      calls.push(["list", options]);
      return {
        blobs: [{ pathname: "message-openers/test.json", url: "https://blob.test/test" }],
        hasMore: false,
      };
    },
    async del(target, options) {
      calls.push(["del", target, options]);
    },
  };
  const storage = _internals.createBlobStorage({ token: "token", sdk });

  await storage.put("message-openers/test.json", "ciphertext");
  const stored = await storage.get("message-openers/test.json");
  const page = await storage.list();
  const read = await storage.read(page.items[0]);
  await storage.delete(stored.target);

  assert.equal(stored.body, "body:message-openers/test.json");
  assert.equal(read, "body:https://blob.test/test");
  assert.deepEqual(calls[1], [
    "get",
    "message-openers/test.json",
    { access: "public", useCache: false, token: "token" },
  ]);
  assert.equal(calls[2][1].prefix, _internals.PREFIX);
  assert.equal(calls[3][2].useCache, false);
});

test("cleanup endpoint requires the cron bearer token", async () => {
  const storage = makeStorage();
  const handler = createHandler({ env: ENV, storage, now: () => FIXED_NOW });
  const denied = await invoke(handler, { action: "cleanup" });
  const allowed = await invoke(handler, {
    action: "cleanup",
    headers: { authorization: `Bearer ${ENV.CRON_SECRET}` },
  });
  assert.equal(denied.statusCode, 401);
  assert.equal(allowed.statusCode, 200);
  assert.deepEqual(JSON.parse(allowed.body), { deleted: 0, failed: 0 });
});

test("vercel routes expose the public create, open, and authenticated cleanup paths", () => {
  const vercel = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "vercel.json"), "utf8"));
  const routes = new Map(vercel.rewrites.map((route) => [route.source, route.destination]));
  assert.equal(routes.get("/v1/links"), "/api/message-opener?action=create");
  assert.equal(routes.get("/t/:id"), "/api/message-opener?action=open&id=:id");
  assert.equal(
    routes.get("/v1/internal/message-opener-cleanup"),
    "/api/message-opener?action=cleanup"
  );
  assert.deepEqual(vercel.crons, [
    { path: "/v1/internal/message-opener-cleanup", schedule: "17 8 * * *" },
  ]);
});
