import { Database } from "bun:sqlite";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync } from "node:fs";
import { OAUTH_SCOPE } from "./scopes.ts";

export const secret = () => randomBytes(32).toString("base64url");
export const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
export const equal = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export interface Host { id: string; user: string; credential: string; created: number }
export interface Token { digest: string; host: string; user: string; client: string; resource: string; expires: number; policy: number; scope: string; family: string }
interface RefreshToken { digest: string; family: string; host: string; user: string; client: string; resource: string; scope: string; expires: number; policy: number; used: number; used_at: number }
export interface Grant { family: string; host: string; user: string; client: string; resource: string; scope: string }
export interface IssuedGrant { access_token: string; refresh_token: string; scope: string }
export const TOKEN_POLICY = 2;
export const ACCESS_TOKEN_LIFETIME_MS = 3_600_000;
export const REFRESH_TOKEN_LIFETIME_MS = 30 * 24 * 3_600_000;
/** A rotated refresh token presented again this soon is a concurrent or retried refresh, not a replay. */
export const REFRESH_REUSE_GRACE_MS = 30_000;
/** Rotated rows stay this long so a late replay still revokes the family, then they are pruned. */
const USED_RETENTION_MS = 24 * 3_600_000;
const ACCESS_TOKENS_PER_FAMILY = 30;
const ACCESS_TOKENS_PER_HOST = 300;
const REFRESH_TOKENS_PER_HOST = 30;

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
      CREATE TABLE IF NOT EXISTS refresh_tokens (digest TEXT PRIMARY KEY, family TEXT NOT NULL, host TEXT NOT NULL, user TEXT NOT NULL, client TEXT NOT NULL, resource TEXT NOT NULL, scope TEXT NOT NULL, expires INTEGER NOT NULL, policy INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, used_at INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS refresh_tokens_host ON refresh_tokens(host);
      CREATE INDEX IF NOT EXISTS refresh_tokens_family ON refresh_tokens(family);`);
    // Tokens issued before grant metadata existed were consented with every scope. Record that
    // explicitly so authorization can fail closed on a missing grant row.
    this.db.query("INSERT OR IGNORE INTO token_grants (digest, family, scope) SELECT digest, '', ? FROM tokens WHERE digest NOT IN (SELECT digest FROM token_grants)").run(OAUTH_SCOPE);
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
    this.db.query("DELETE FROM refresh_tokens WHERE expires <= ? OR (used = 1 AND used_at <= ?)").run(now, now - USED_RETENTION_MS);
  }
  issueToken(token: { host: string; user: string; client: string; resource: string; expires: number; scope?: string; family?: string }, now = Date.now()) {
    this.expire(now);
    const family = token.family ?? "";
    const inFamily = family ? this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM token_grants WHERE family = ?").get(family)!.n : 0;
    const onHost = this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM tokens WHERE host = ?").get(token.host)!.n;
    if (inFamily >= ACCESS_TOKENS_PER_FAMILY || onHost >= ACCESS_TOKENS_PER_HOST || (!family && onHost >= ACCESS_TOKENS_PER_FAMILY)) throw new Error("Token limit");
    const raw = secret();
    this.db.transaction(() => {
      this.db.query("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, ?)").run(hash(raw), token.host, token.user, token.client, token.resource, token.expires, TOKEN_POLICY);
      this.db.query("INSERT INTO token_grants VALUES (?, ?, ?)").run(hash(raw), family, token.scope ?? OAUTH_SCOPE);
    })();
    return raw;
  }
  authorize(raw: string, hostID: string, resource: string, now = Date.now()): Token | null {
    const row = this.db.query<Token, [string]>(
      "SELECT t.digest, t.host, t.user, t.client, t.resource, t.expires, t.policy, g.scope, g.family FROM tokens t JOIN token_grants g ON g.digest = t.digest WHERE t.digest = ?").get(hash(raw));
    const host = this.host(hostID);
    return row && host && row.expires > now && row.policy === TOKEN_POLICY && row.host === hostID && row.resource === resource && row.user === host.user ? row : null;
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
  private revokeFamily(family: string) {
    if (!family) return;
    this.db.query("DELETE FROM tokens WHERE digest IN (SELECT digest FROM token_grants WHERE family = ?)").run(family);
    this.db.query("DELETE FROM token_grants WHERE family = ?").run(family);
    this.db.query("DELETE FROM refresh_tokens WHERE family = ?").run(family);
  }
  private issueRefreshToken(grant: Grant & { expires: number }, now: number) {
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM refresh_tokens WHERE host = ? AND used = 0").get(grant.host)!.n >= REFRESH_TOKENS_PER_HOST) throw new Error("Token limit");
    const raw = secret();
    this.db.query("INSERT INTO refresh_tokens VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)").run(hash(raw), grant.family, grant.host, grant.user, grant.client, grant.resource, grant.scope, grant.expires, TOKEN_POLICY);
    return raw;
  }
  /** Issue an access token and its refresh token together, or neither. Throws "Token limit" when a cap is hit. */
  issueGrant(grant: Grant, now = Date.now()): IssuedGrant {
    return this.db.transaction(() => {
      const access_token = this.issueToken({ ...grant, expires: now + ACCESS_TOKEN_LIFETIME_MS }, now);
      const refresh_token = this.issueRefreshToken({ ...grant, expires: now + REFRESH_TOKEN_LIFETIME_MS }, now);
      return { access_token, refresh_token, scope: grant.scope };
    })();
  }
  /**
   * Rotate a refresh token in one transaction. `decide` sees the stored grant and returns the scope to
   * issue, or null to refuse without consuming the token (a client mistake, not a replay). A rotated
   * token presented again within the grace window gets another pair for the same family; a later replay
   * revokes the family, since either the client or a thief kept a token that should have been discarded.
   * Returns null when the token is unknown, expired, replayed, or refused. Throws "Token limit" and
   * leaves the presented token usable when a cap prevents issuing.
   */
  rotateRefreshToken(raw: string, now: number, decide: (grant: Grant) => string | null): IssuedGrant | null {
    const digest = hash(raw);
    return this.db.transaction(() => {
      const row = this.db.query<RefreshToken, [string]>("SELECT * FROM refresh_tokens WHERE digest = ?").get(digest);
      if (!row) return null;
      if (row.used && now - row.used_at > REFRESH_REUSE_GRACE_MS) { this.revokeFamily(row.family); return null; }
      const host = this.host(row.host);
      if (row.expires <= now || row.policy !== TOKEN_POLICY || !host || host.user !== row.user) {
        this.db.query("DELETE FROM refresh_tokens WHERE digest = ?").run(digest);
        return null;
      }
      const grant: Grant = { family: row.family, host: row.host, user: row.user, client: row.client, resource: row.resource, scope: row.scope };
      const scope = decide(grant);
      if (scope === null) return null;
      if (!row.used) this.db.query("UPDATE refresh_tokens SET used = 1, used_at = ? WHERE digest = ?").run(now, digest);
      return this.issueGrant({ ...grant, scope }, now);
    })();
  }
  hostAuthorized(id: string, raw: string) {
    const host = this.host(id);
    return host && equal(host.credential, hash(raw)) ? host : null;
  }
}
