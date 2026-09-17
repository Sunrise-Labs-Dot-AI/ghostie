import { afterEach, describe, expect, test } from "bun:test";
import { Authorization, OAUTH_SCOPE, oauthRedirectURI } from "./authorization.ts";
import { hash, secret, Store } from "./store.ts";

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
    for (const scope of ["messages:read", "messages:read messages:draft"])
      expect(() => f.auth.approveConsent({ ...f.consent, scope }, "user-a")).toThrow();
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
