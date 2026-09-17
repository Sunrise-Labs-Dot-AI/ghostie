import { afterEach, describe, expect, test } from "bun:test";
import { Authorization, OAUTH_SCOPE, oauthRedirectURI } from "./authorization.ts";
import { hash, secret, REFRESH_REUSE_GRACE_MS, Store } from "./store.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const stores: Store[] = [];
afterEach(() => { for (const store of stores.splice(0)) store.db.close(); });
function fixture() {
  const store = new Store(":memory:"); stores.push(store);
  let now = Date.now();
  const auth = new Authorization(store, "https://relay.example.test", [{ id: "client", name: "Test client", redirects: ["https://client.example.test/callback"] }], () => now);
  const proof = secret(); const pair = auth.startPair(hash(proof));
  auth.approvePair(pair.id, pair.code, "user-a");
  const paired = auth.pollPair(pair.id, proof);
  const verifier = secret();
  const consent = { client_id: "client", redirect_uri: "https://client.example.test/callback", response_type: "code", code_challenge_method: "S256", code_challenge: hash(verifier), state: "client-state", resource: auth.resource(paired.host!) };
  const exchange = () => {
    const url = new URL(auth.approveConsent(consent, "user-a"));
    expect(url.searchParams.get("state")).toBe(consent.state);
    return { grant_type: "authorization_code", code: url.searchParams.get("code")!, client_id: consent.client_id, redirect_uri: consent.redirect_uri, resource: consent.resource, code_verifier: verifier };
  };
  return { store, auth, proof, pair, paired, consent, exchange, advance: (ms: number) => { now += ms; } };
}

test("configured callbacks allow Cursor and numeric loopback, rejecting unsafe hosts", () => {
  for (const uri of ["http://localhost:8787/callback", "https://www.cursor.com/agents/mcp/oauth/callback",
    "http://127.0.0.1:18764/callback", "http://[::1]:8787/callback"]) {
    expect(oauthRedirectURI.safeParse(uri).success).toBe(true);
  }
  for (const uri of ["http://localhost.evil.test:8787/callback", "http://sub.localhost:8787/callback",
    "http://localhost.:8787/callback", "http://external.example/callback", "http://user@localhost:8787/callback",
    "http://localhost:8787/callback#fragment", "ftp://localhost/callback"]) {
    expect(oauthRedirectURI.safeParse(uri).success).toBe(false);
  }
});

test("Cursor public client requires exact registered callback and PKCE", () => {
  const f = fixture();
  const callbacks = ["http://localhost:8787/callback", "https://www.cursor.com/agents/mcp/oauth/callback"];
  f.auth.clients.push({ id: "ghostie-cursor", name: "Grok Bot / Cursor", redirects: callbacks });
  for (const redirect_uri of callbacks) {
    const proof = secret();
    const request = { ...f.consent, client_id: "ghostie-cursor", redirect_uri, code_challenge: hash(proof) };
    const redirect = new URL(f.auth.approveConsent(request, "user-a"));
    const token = f.auth.exchange({ grant_type: "authorization_code", code: redirect.searchParams.get("code"),
      client_id: request.client_id, redirect_uri, resource: request.resource, code_verifier: proof });
    expect(f.store.authorize(token.access_token, f.paired.host!, request.resource)?.client).toBe("ghostie-cursor");
    expect(() => f.auth.approveConsent(request, "user-b")).toThrow();
    for (const changed of [redirect_uri + "/", redirect_uri + "%2f", redirect_uri + "?extra=1"])
      expect(() => f.auth.approveConsent({ ...request, redirect_uri: changed }, "user-a")).toThrow();
  }
  for (const changed of ["http://LOCALHOST:8787/callback", "http://%6cocalhost:8787/callback",
    "http://localhost:8788/callback", "http://127.0.0.1:8787/callback",
    "https://www.cursor.com:443/agents/mcp/oauth/callback"]) {
    expect(() => f.auth.approveConsent({ ...f.consent, client_id: "ghostie-cursor", redirect_uri: changed }, "user-a")).toThrow();
  }
});

describe("pairing", () => {
  test("only the initiating Mac can poll and approval cannot be replayed", () => {
    const f = fixture();
    expect(() => f.auth.pollPair(f.pair.id, secret())).toThrow();
    expect(() => f.auth.approvePair(f.pair.id, f.pair.code, "user-b")).toThrow();
    expect(f.store.hostAuthorized(f.paired.host!, f.proof)?.user).toBe("user-a");
    expect(f.store.hostAuthorized(f.paired.host!, secret())).toBeNull();
  });
  test("wrong code cannot bind and expiry denies every polling proof", () => {
    const f = fixture(); const pending = f.auth.startPair(hash(secret()));
    expect(() => f.auth.approvePair(pending.id, "WRONG123", "user-a")).toThrow();
    f.advance(300_001);
    expect(() => f.auth.pollPair(f.pair.id, f.proof)).toThrow();
  });
  test("cancel removes an already approved host and its access", () => {
    const f = fixture(); f.auth.cancelPair(f.pair.id, f.proof);
    expect(f.store.host(f.paired.host!)).toBeNull();
    expect(() => f.auth.pollPair(f.pair.id, f.proof)).toThrow();
  });
});

describe("host-bound OAuth", () => {
  test("exchanges S256 once, returns bound token, stores no bearer secrets", () => {
    const f = fixture(); const exchange = f.exchange(); const token = f.auth.exchange(exchange);
    expect(token.scope).toBe(OAUTH_SCOPE);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)?.client).toBe("client");
    expect(() => f.auth.exchange(exchange)).toThrow();
    const rows = JSON.stringify(f.store.db.query("SELECT * FROM tokens").all());
    expect(rows).not.toContain(token.access_token); expect(rows).not.toContain(f.proof);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource, Date.now() + 3_600_001)).toBeNull();
    f.store.revoke(token.access_token);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)).toBeNull();
  });
  test("invalidates tokens issued under the pre-link consent policy", () => {
    const f = fixture();
    const legacy = secret();
    f.store.db.query("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, 1)").run(
      hash(legacy), f.paired.host!, "user-a", "client", f.consent.resource, Date.now() + 60_000,
    );
    expect(f.store.authorize(legacy, f.paired.host!, f.consent.resource)).toBeNull();
  });
  for (const field of ["code_verifier", "redirect_uri", "resource", "client_id"] as const) {
    test(`refuses wrong ${field} and consumes code`, () => {
      const f = fixture(); const exchange = f.exchange();
      expect(() => f.auth.exchange({ ...exchange, [field]: field === "code_verifier" ? secret() : "wrong" })).toThrow();
      expect(() => f.auth.exchange(exchange)).toThrow();
    });
  }
  test("rejects cross-account consent, PKCE downgrade and redirect wildcard", () => {
    const f = fixture();
    expect(() => f.auth.approveConsent(f.consent, "user-b")).toThrow();
    expect(() => f.auth.approveConsent({ ...f.consent, code_challenge_method: "plain" }, "user-a")).toThrow();
    expect(() => f.auth.approveConsent({ ...f.consent, redirect_uri: "https://client.example.test/other" }, "user-a")).toThrow();
    expect(() => f.auth.approveConsent({ ...f.consent, resource: f.consent.resource + "?other" }, "user-a")).toThrow();
    for (const scope of ["", "messages:send", "offline_access", "messages:read admin"])
      expect(() => f.auth.approveConsent({ ...f.consent, scope }, "user-a")).toThrow();
  });
  test("consent grants any subset of the supported scopes and the token carries it", () => {
    const f = fixture();
    for (const [requested, granted] of [["messages:read messages:draft", "messages:read messages:draft"], ["messages:draft messages:read offline_access", "messages:read messages:draft"], ["messages:read", "messages:read"]] as [string, string][]) {
      const verifier = secret();
      const url = new URL(f.auth.approveConsent({ ...f.consent, scope: requested, code_challenge: hash(verifier) }, "user-a"));
      const token = f.auth.exchange({ grant_type: "authorization_code", code: url.searchParams.get("code")!, client_id: "client", redirect_uri: f.consent.redirect_uri, resource: f.consent.resource, code_verifier: verifier });
      expect(token.scope).toBe(granted);
      expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)?.scope).toBe(granted);
    }
  });
  test("expiry and host deletion revoke authority", () => {
    const f = fixture(); const expired = f.exchange(); f.advance(60_001);
    expect(() => f.auth.exchange(expired)).toThrow();
    const token = f.auth.exchange(f.exchange());
    const secondID = secret(); f.store.addHost({ id: secondID, user: "user-a", credential: hash(secret()), created: Date.now() });
    expect(f.store.authorize(token.access_token, secondID, f.auth.resource(secondID))).toBeNull();
    f.store.deleteHost(f.paired.host!);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)).toBeNull();
  });
});

describe("refresh tokens", () => {
  const refresh = (f: ReturnType<typeof fixture>, refresh_token: string, extra: Record<string, string> = {}) =>
    f.auth.exchange({ grant_type: "refresh_token", refresh_token, client_id: "client", resource: f.consent.resource, ...extra });
  test("code exchange issues a refresh token that rotates on use and expires after 30 days", () => {
    const f = fixture(); const first = f.auth.exchange(f.exchange());
    expect(first.refresh_token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(first.refresh_token).not.toBe(first.access_token);
    f.advance(3_600_001);
    expect(f.store.authorize(first.access_token, f.paired.host!, f.consent.resource, Date.now() + 3_600_001)).toBeNull();
    const second = refresh(f, first.refresh_token);
    expect(second.scope).toBe(OAUTH_SCOPE);
    expect(second.refresh_token).not.toBe(first.refresh_token);
    expect(f.store.authorize(second.access_token, f.paired.host!, f.consent.resource, Date.now() + 3_600_001)?.client).toBe("client");
    const rows = JSON.stringify(f.store.db.query("SELECT * FROM refresh_tokens").all()) + JSON.stringify(f.store.db.query("SELECT * FROM tokens").all());
    for (const raw of [first.access_token, first.refresh_token, second.access_token, second.refresh_token]) expect(rows).not.toContain(raw);
    f.advance(30 * 24 * 3_600_000 + 1);
    expect(() => refresh(f, second.refresh_token)).toThrow("invalid_grant");
  });
  test("a rotated token reused inside the grace window is a concurrent refresh, after it a replay that revokes the family", () => {
    const f = fixture(); const first = f.auth.exchange(f.exchange());
    const second = refresh(f, first.refresh_token);
    // Two processes of one client racing to refresh both keep working.
    f.advance(REFRESH_REUSE_GRACE_MS - 1);
    const sibling = refresh(f, first.refresh_token);
    expect(sibling.refresh_token).not.toBe(second.refresh_token);
    for (const token of [second.access_token, sibling.access_token]) expect(f.store.authorize(token, f.paired.host!, f.consent.resource, Date.now() + REFRESH_REUSE_GRACE_MS)?.client).toBe("client");
    f.advance(2);
    expect(() => refresh(f, first.refresh_token)).toThrow("invalid_grant");
    for (const token of [second.access_token, sibling.access_token]) expect(f.store.authorize(token, f.paired.host!, f.consent.resource, Date.now() + REFRESH_REUSE_GRACE_MS)).toBeNull();
    for (const token of [second.refresh_token, sibling.refresh_token]) expect(() => refresh(f, token)).toThrow("invalid_grant");
    expect(f.store.db.query("SELECT count(*) n FROM refresh_tokens").get()).toEqual({ n: 0 });
  });
  test("refresh is bound to the client, resource, and host account, and a mismatch does not burn the token", () => {
    const f = fixture(); const issued = f.auth.exchange(f.exchange());
    expect(() => refresh(f, issued.refresh_token, { client_id: "other" })).toThrow("invalid_grant");
    expect(() => refresh(f, issued.refresh_token, { resource: f.consent.resource + "x" })).toThrow("invalid_grant");
    expect(() => f.auth.exchange({ grant_type: "refresh_token", refresh_token: secret(), client_id: "client" })).toThrow("invalid_grant");
    expect(() => f.auth.exchange({ grant_type: "refresh_token", refresh_token: issued.refresh_token })).toThrow("invalid_grant");
    expect(() => f.auth.exchange({ grant_type: "refresh_token", refresh_token: issued.refresh_token, client_id: "client", extra: "field" })).toThrow("invalid_grant");
    expect(f.store.db.query<{ used: number }, []>("SELECT used FROM refresh_tokens").get()?.used).toBe(0);
    const renewed = f.auth.exchange({ grant_type: "refresh_token", refresh_token: issued.refresh_token, client_id: "client" });
    expect(renewed.access_token).toBeTruthy();
    f.auth.clients.splice(0);
    expect(() => refresh(f, renewed.refresh_token)).toThrow("invalid_grant");
  });
  test("a cap hit answers temporarily_unavailable and leaves the presented refresh token usable", () => {
    const f = fixture(); const issued = f.auth.exchange(f.exchange());
    let current = issued;
    for (let count = 0; count < 29; count += 1) current = refresh(f, current.refresh_token);
    expect(() => refresh(f, current.refresh_token)).toThrow("temporarily_unavailable");
    expect(f.store.db.query<{ used: number }, [string]>("SELECT used FROM refresh_tokens WHERE digest = ?").get(hash(current.refresh_token))?.used).toBe(0);
    expect(f.store.db.query("SELECT count(*) n FROM tokens").get()).toEqual({ n: 30 });
    f.advance(3_600_001);
    const renewed = refresh(f, current.refresh_token);
    expect(renewed.access_token).toBeTruthy();
  });
  test("refresh may narrow the granted scope but not widen it, without revealing whether the token is live", () => {
    const f = fixture(); const verifier = secret();
    const url = new URL(f.auth.approveConsent({ ...f.consent, scope: "messages:read messages:draft", code_challenge: hash(verifier) }, "user-a"));
    const issued = f.auth.exchange({ grant_type: "authorization_code", code: url.searchParams.get("code")!, client_id: "client", redirect_uri: f.consent.redirect_uri, resource: f.consent.resource, code_verifier: verifier });
    expect(() => refresh(f, issued.refresh_token, { scope: OAUTH_SCOPE })).toThrow("invalid_grant");
    expect(() => refresh(f, issued.refresh_token, { scope: "messages:send" })).toThrow("invalid_grant");
    expect(() => refresh(f, secret(), { scope: "messages:send" })).toThrow("invalid_grant");
    expect(f.store.db.query<{ used: number }, []>("SELECT used FROM refresh_tokens").get()?.used).toBe(0);
    const narrowed = refresh(f, issued.refresh_token, { scope: "messages:read" });
    expect(narrowed.scope).toBe("messages:read");
    expect(f.store.authorize(narrowed.access_token, f.paired.host!, f.consent.resource)?.scope).toBe("messages:read");
  });
  test("revoking a refresh token, disconnecting the Mac, or a wrong-user host ends the grant", () => {
    const f = fixture(); const issued = f.auth.exchange(f.exchange());
    f.store.revoke(issued.refresh_token);
    expect(f.store.authorize(issued.access_token, f.paired.host!, f.consent.resource)).toBeNull();
    expect(() => refresh(f, issued.refresh_token)).toThrow("invalid_grant");
    const again = f.auth.exchange(f.exchange());
    f.store.deleteHost(f.paired.host!);
    expect(() => refresh(f, again.refresh_token)).toThrow("invalid_grant");
    expect(f.store.db.query("SELECT count(*) n FROM refresh_tokens").get()).toEqual({ n: 0 });
  });
  test("tokens issued by the previous build are backfilled with the full scope on startup, and a missing grant row fails closed", () => {
    const dir = mkdtempSync(join(tmpdir(), "ghostie-relay-store-"));
    try {
      const path = join(dir, "relay.sqlite");
      const before = new Store(path); const legacy = secret(); const host = secret();
      before.addHost({ id: host, user: "user-a", credential: hash(secret()), created: Date.now() });
      before.db.query("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, 2)").run(hash(legacy), host, "user-a", "client", `https://relay.example.test/mcp/hosts/${host}`, Date.now() + 60_000);
      expect(before.authorize(legacy, host, `https://relay.example.test/mcp/hosts/${host}`)).toBeNull();
      before.db.close();
      const after = new Store(path); stores.push(after);
      const token = after.authorize(legacy, host, `https://relay.example.test/mcp/hosts/${host}`);
      expect(token?.scope).toBe(OAUTH_SCOPE);
      expect(token?.family).toBe("");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});
