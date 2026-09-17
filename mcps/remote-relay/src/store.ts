import { Database } from "bun:sqlite";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync } from "node:fs";
import { OAUTH_SCOPE } from "./scopes.ts";

export const secret = () => randomBytes(32).toString("base64url");
export const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
export const equal = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export interface Host { id: string; user: string; credential: string; created: number }
export interface Token { digest: string; host: string; user: string; client: string; resource: string; expires: number; policy: number; scope: string; family: string }
interface RefreshToken { digest: string; family: string; host: string; user: string; client: string; resource: string; scope: string; expires: number; policy: number; used: number }
export interface Grant { family: string; host: string; user: string; client: string; resource: string; scope: string }
export const TOKEN_POLICY = 2;
export const REFRESH_TOKEN_LIFETIME_MS = 30 * 24 * 3_600_000;
const ACCESS_TOKEN_LIMIT = 30;
const REFRESH_TOKEN_LIMIT = 30;

export class Store {
  readonly db: Database;
  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: true });
    if (path !== ":memory:") chmodSync(path, 0o600);
    // `tokens` keeps its original shape so an earlier relay build can still read and insert it.
    // Grant scope and family live beside it; refresh tokens have their own table.
    this.db.exec(`PRAGMA journal_mode = DELETE;
      CREATE TABLE IF NOT EXISTS hosts (id TEXT PRIMARY KEY, user TEXT NOT NULL, credential TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens (digest TEXT PRIMARY KEY, host TEXT NOT NULL, user TEXT NOT NULL, client TEXT NOT NULL, resource TEXT NOT NULL, expires INTEGER NOT NULL, policy INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS tokens_host ON tokens(host);
      CREATE TABLE IF NOT EXISTS token_grants (digest TEXT PRIMARY KEY, family TEXT NOT NULL, scope TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS token_grants_family ON token_grants(family);
      CREATE TABLE IF NOT EXISTS refresh_tokens (digest TEXT PRIMARY KEY, family TEXT NOT NULL, host TEXT NOT NULL, user TEXT NOT NULL, client TEXT NOT NULL, resource TEXT NOT NULL, scope TEXT NOT NULL, expires INTEGER NOT NULL, policy INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS refresh_tokens_host ON refresh_tokens(host);
      CREATE INDEX IF NOT EXISTS refresh_tokens_family ON refresh_tokens(family);`);
  }
  host(id: string) { return this.db.query<Host, [string]>("SELECT * FROM hosts WHERE id = ?").get(id); }
  addHost(host: Host) {
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM hosts WHERE user = ?").get(host.user)!.n >= 10) throw new Error("Host limit");
    this.db.query("INSERT INTO hosts VALUES (?, ?, ?, ?)").run(host.id, host.user, host.credential, host.created);
  }
  deleteHost(id: string) {
    this.db.transaction(() => {
      this.db.query("DELETE FROM token_grants WHERE digest IN (SELECT digest FROM tokens WHERE host = ?)").run(id);
      this.db.query("DELETE FROM tokens WHERE host = ?").run(id);
      this.db.query("DELETE FROM refresh_tokens WHERE host = ?").run(id);
      this.db.query("DELETE FROM hosts WHERE id = ?").run(id);
    })();
  }
  private expire(now: number) {
    this.db.query("DELETE FROM token_grants WHERE digest IN (SELECT digest FROM tokens WHERE expires <= ?)").run(now);
    this.db.query("DELETE FROM tokens WHERE expires <= ?").run(now);
    this.db.query("DELETE FROM refresh_tokens WHERE expires <= ?").run(now);
  }
  issueToken(token: { host: string; user: string; client: string; resource: string; expires: number; scope?: string; family?: string }, now = Date.now()) {
    this.expire(now);
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM tokens WHERE host = ?").get(token.host)!.n >= ACCESS_TOKEN_LIMIT) throw new Error("Token limit");
    const raw = secret();
    this.db.transaction(() => {
      this.db.query("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, ?)").run(hash(raw), token.host, token.user, token.client, token.resource, token.expires, TOKEN_POLICY);
      this.db.query("INSERT INTO token_grants VALUES (?, ?, ?)").run(hash(raw), token.family ?? "", token.scope ?? OAUTH_SCOPE);
    })();
    return raw;
  }
  authorize(raw: string, hostID: string, resource: string, now = Date.now()): Token | null {
    const row = this.db.query<Omit<Token, "scope" | "family"> & { scope: string | null; family: string | null }, [string]>(
      "SELECT t.*, g.scope AS scope, g.family AS family FROM tokens t LEFT JOIN token_grants g ON g.digest = t.digest WHERE t.digest = ?").get(hash(raw));
    const host = this.host(hostID);
    if (!(row && host && row.expires > now && row.policy === TOKEN_POLICY && row.host === hostID && row.resource === resource && row.user === host.user)) return null;
    return { ...row, scope: row.scope ?? OAUTH_SCOPE, family: row.family ?? "" };
  }
  /** Revoke one presented token. A refresh token takes its whole grant family with it (RFC 7009). */
  revoke(raw: string) {
    const digest = hash(raw);
    this.db.transaction(() => {
      const refresh = this.db.query<{ family: string }, [string]>("SELECT family FROM refresh_tokens WHERE digest = ?").get(digest);
      this.db.query("DELETE FROM token_grants WHERE digest = ?").run(digest);
      this.db.query("DELETE FROM tokens WHERE digest = ?").run(digest);
      if (refresh) this.revokeFamily(refresh.family);
    })();
  }
  revokeFamily(family: string) {
    if (!family) return;
    this.db.query("DELETE FROM tokens WHERE digest IN (SELECT digest FROM token_grants WHERE family = ?)").run(family);
    this.db.query("DELETE FROM token_grants WHERE family = ?").run(family);
    this.db.query("DELETE FROM refresh_tokens WHERE family = ?").run(family);
  }
  issueRefreshToken(grant: Grant & { expires: number }, now = Date.now()) {
    this.expire(now);
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM refresh_tokens WHERE host = ? AND used = 0").get(grant.host)!.n >= REFRESH_TOKEN_LIMIT) throw new Error("Token limit");
    const raw = secret();
    this.db.query("INSERT INTO refresh_tokens VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)").run(hash(raw), grant.family, grant.host, grant.user, grant.client, grant.resource, grant.scope, grant.expires, TOKEN_POLICY);
    return raw;
  }
  /**
   * Consume a refresh token and return the grant to renew, or null. Each token is single-use;
   * presenting an already rotated token revokes the whole family, since either the client or a thief replayed it.
   */
  redeemRefreshToken(raw: string, now = Date.now(), accept: (grant: Grant) => boolean = () => true): Grant | null {
    const digest = hash(raw);
    return this.db.transaction(() => {
      const row = this.db.query<RefreshToken, [string]>("SELECT * FROM refresh_tokens WHERE digest = ?").get(digest);
      if (!row) return null;
      if (row.used) { this.revokeFamily(row.family); return null; }
      const host = this.host(row.host);
      if (row.expires <= now || row.policy !== TOKEN_POLICY || !host || host.user !== row.user) {
        this.db.query("DELETE FROM refresh_tokens WHERE digest = ?").run(digest);
        return null;
      }
      const grant = { family: row.family, host: row.host, user: row.user, client: row.client, resource: row.resource, scope: row.scope };
      // A mismatched binding or scope is a client mistake, not a replay: leave the token usable.
      if (!accept(grant)) return null;
      this.db.query("UPDATE refresh_tokens SET used = 1 WHERE digest = ?").run(digest);
      return grant;
    })();
  }
  hostAuthorized(id: string, raw: string) {
    const host = this.host(id);
    return host && equal(host.credential, hash(raw)) ? host : null;
  }
}
