import { z } from "zod";
import { equal, hash, secret, Store } from "./store.ts";

export interface OAuthClient { id: string; name: string; redirects: string[] }
export const oauthRedirectURI = z.string().url().refine(value => {
  const url = new URL(value);
  // Cursor uses localhost for its fixed desktop callback. Consent still matches the full URI exactly.
  return !url.hash && !url.username && !url.password && (url.protocol === "https:" ||
    (url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)));
});
export const consentSchema = z.object({
  client_id: z.string().min(1).max(200), redirect_uri: z.string().url().max(2000),
  response_type: z.literal("code"), code_challenge_method: z.literal("S256"),
  code_challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  state: z.string().min(1).max(1024), resource: z.string().url().max(2000),
  scope: z.literal("messages:read messages:draft").default("messages:read messages:draft"),
});
type Consent = z.infer<typeof consentSchema>;
interface Code { request: Consent; host: string; user: string; expires: number }
interface Pair { digest: string; code: string; expires: number; host?: string; user?: string }

export class Authorization {
  readonly codes = new Map<string, Code>();
  readonly pairs = new Map<string, Pair>();
  constructor(readonly store: Store, readonly origin: string, readonly clients: OAuthClient[], readonly now = Date.now) {}
  cleanup() {
    for (const [id, value] of this.codes) if (value.expires <= this.now()) this.codes.delete(id);
    for (const [id, value] of this.pairs) if (value.expires <= this.now()) this.pairs.delete(id);
  }
  resource(host: string) { return `${this.origin}/mcp/hosts/${host}`; }
  startPair(digest: string) {
    this.cleanup();
    if (!/^[A-Za-z0-9_-]{43}$/.test(digest) || this.pairs.size >= 100) throw new Error("Pair unavailable");
    const id = secret();
    const code = secret().slice(0, 8).toUpperCase();
    this.pairs.set(id, { digest, code, expires: this.now() + 300_000 });
    return { id, code, url: `${this.origin}/pair?id=${id}`, expires_in: 300 };
  }
  approvePair(id: string, code: string, user: string) {
    this.cleanup();
    const pair = this.pairs.get(id);
    if (!pair || pair.host || !equal(pair.code, code)) throw new Error("Pair unavailable");
    const host = secret();
    this.store.addHost({ id: host, user, credential: pair.digest, created: this.now() });
    pair.host = host;
    pair.user = user;
  }
  pollPair(id: string, proof: string) {
    this.cleanup();
    const pair = this.pairs.get(id);
    if (!pair || !equal(pair.digest, hash(proof))) throw new Error("Pair unavailable");
    return pair.host ? { status: "paired", host: pair.host, user: pair.user, mcp_url: this.resource(pair.host) } : { status: "pending" };
  }
  cancelPair(id: string, proof: string) {
    const pair = this.pairs.get(id);
    if (!pair || !equal(pair.digest, hash(proof))) throw new Error("Pair unavailable");
    if (pair.host) this.store.deleteHost(pair.host);
    this.pairs.delete(id);
  }
  validateConsent(raw: unknown, user: string) {
    const request = consentSchema.parse(raw);
    const client = this.clients.find(c => c.id === request.client_id && c.redirects.includes(request.redirect_uri));
    const hostID = request.resource.startsWith(`${this.origin}/mcp/hosts/`) ? request.resource.slice(`${this.origin}/mcp/hosts/`.length) : "";
    const host = this.store.host(hostID);
    if (!client || !host || host.user !== user || request.resource !== this.resource(host.id)) throw new Error("Consent unavailable");
    return { request, client, host };
  }
  approveConsent(raw: unknown, user: string) {
    this.cleanup();
    const { request, host } = this.validateConsent(raw, user);
    if (this.codes.size >= 100) throw new Error("Consent unavailable");
    const code = secret();
    this.codes.set(hash(code), { request, host: host.id, user, expires: this.now() + 60_000 });
    const redirect = new URL(request.redirect_uri);
    redirect.searchParams.set("code", code);
    redirect.searchParams.set("state", request.state);
    return redirect.href;
  }
  exchange(raw: unknown) {
    this.cleanup();
    const params = z.object({ grant_type: z.literal("authorization_code"), code: z.string().max(100),
      client_id: z.string().max(200), redirect_uri: z.string().max(2000), resource: z.string().max(2000),
      code_verifier: z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/),
    }).strict().parse(raw);
    const key = hash(params.code);
    const code = this.codes.get(key);
    this.codes.delete(key); // consume on any exchange attempt, including bad proof
    if (!code || !equal(hash(params.code_verifier), code.request.code_challenge) ||
      params.client_id !== code.request.client_id || params.redirect_uri !== code.request.redirect_uri ||
      params.resource !== code.request.resource || this.store.host(code.host)?.user !== code.user) throw new Error("invalid_grant");
    return { access_token: this.store.issueToken({ host: code.host, user: code.user, client: params.client_id,
      resource: params.resource, expires: this.now() + 3_600_000 }), token_type: "Bearer", expires_in: 3600,
      scope: "messages:read messages:draft" };
  }
}
