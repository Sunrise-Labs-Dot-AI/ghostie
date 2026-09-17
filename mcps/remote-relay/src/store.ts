import { Database } from "bun:sqlite";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync } from "node:fs";

export const secret = () => randomBytes(32).toString("base64url");
export const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
export const equal = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export interface Host { id: string; user: string; credential: string; created: number }
interface Token { digest: string; host: string; user: string; client: string; resource: string; expires: number; policy: number }
export const TOKEN_POLICY = 2;
export class Store {
  readonly db: Database;
  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: true });
    if (path !== ":memory:") chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode = DELETE;
      CREATE TABLE IF NOT EXISTS hosts (id TEXT PRIMARY KEY, user TEXT NOT NULL, credential TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens (digest TEXT PRIMARY KEY, host TEXT NOT NULL, user TEXT NOT NULL, client TEXT NOT NULL, resource TEXT NOT NULL, expires INTEGER NOT NULL, policy INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS tokens_host ON tokens(host);`);
  }
  host(id: string) { return this.db.query<Host, [string]>("SELECT * FROM hosts WHERE id = ?").get(id); }
  addHost(host: Host) {
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM hosts WHERE user = ?").get(host.user)!.n >= 10) throw new Error("Host limit");
    this.db.query("INSERT INTO hosts VALUES (?, ?, ?, ?)").run(host.id, host.user, host.credential, host.created);
  }
  deleteHost(id: string) {
    this.db.transaction(() => {
      this.db.query("DELETE FROM tokens WHERE host = ?").run(id);
      this.db.query("DELETE FROM hosts WHERE id = ?").run(id);
    })();
  }
  issueToken(token: Omit<Token, "digest" | "policy">) {
    this.db.query("DELETE FROM tokens WHERE expires <= ?").run(Date.now());
    if (this.db.query<{ n: number }, [string]>("SELECT count(*) n FROM tokens WHERE host = ?").get(token.host)!.n >= 30) throw new Error("Token limit");
    const raw = secret();
    this.db.query("INSERT INTO tokens VALUES (?, ?, ?, ?, ?, ?, ?)").run(hash(raw), token.host, token.user, token.client, token.resource, token.expires, TOKEN_POLICY);
    return raw;
  }
  authorize(raw: string, hostID: string, resource: string, now = Date.now()) {
    const token = this.db.query<Token, [string]>("SELECT * FROM tokens WHERE digest = ?").get(hash(raw));
    const host = this.host(hostID);
    return token && host && token.expires > now && token.policy === TOKEN_POLICY && token.host === hostID && token.resource === resource && token.user === host.user ? token : null;
  }
  revoke(raw: string) { this.db.query("DELETE FROM tokens WHERE digest = ?").run(hash(raw)); }
  hostAuthorized(id: string, raw: string) {
    const host = this.host(id);
    return host && equal(host.credential, hash(raw)) ? host : null;
  }
}
