import { afterEach, describe, expect, test } from "bun:test";
import { Authorization } from "./authorization.ts";
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
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)?.client).toBe("client");
    expect(() => f.auth.exchange(exchange)).toThrow();
    const rows = JSON.stringify(f.store.db.query("SELECT * FROM tokens").all());
    expect(rows).not.toContain(token.access_token); expect(rows).not.toContain(f.proof);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource, Date.now() + 3_600_001)).toBeNull();
    f.store.revoke(token.access_token);
    expect(f.store.authorize(token.access_token, f.paired.host!, f.consent.resource)).toBeNull();
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
