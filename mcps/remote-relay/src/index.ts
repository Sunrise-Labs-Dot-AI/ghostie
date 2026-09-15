import { createClerkClient } from "@clerk/backend";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { z } from "zod";
import { Store } from "./store.ts";
import { startRelay } from "./server.ts";

const httpsOrigin = z.string().url().refine(value => {
  const url = new URL(value);
  return url.protocol === "https:" && url.origin === value && !url.username && !url.password;
});
const config = z.object({
  GHOSTIE_RELAY_ORIGIN: httpsOrigin,
  CLERK_PUBLISHABLE_KEY: z.string().regex(/^pk_(test|live)_/),
  CLERK_SECRET_KEY: z.string().regex(/^sk_(test|live)_/),
  CLERK_FRONTEND_ORIGIN: httpsOrigin,
  GHOSTIE_RELAY_DB: z.string().min(1),
  GHOSTIE_OAUTH_CLIENTS: z.string().transform(value => JSON.parse(value)).pipe(z.array(z.object({
    id: z.string().min(1).max(200), name: z.string().min(1).max(100),
    redirects: z.array(z.string().url().refine(value => {
      const url = new URL(value);
      return !url.hash && !url.username && !url.password && (url.protocol === "https:" || (url.protocol === "http:" && ["127.0.0.1", "[::1]"].includes(url.hostname)));
    })).min(1),
  }).strict()).min(1)),
}).safeParse(process.env);
if (!config.success) {
  // Never print the parser's input, which includes the Clerk secret.
  process.stderr.write("Remote relay configuration is missing or invalid. See README.\n");
  process.exit(1);
}
const env = config.data;
mkdirSync(dirname(env.GHOSTIE_RELAY_DB), { recursive: true, mode: 0o700 });
const store = new Store(env.GHOSTIE_RELAY_DB);
const clerk = createClerkClient({ secretKey: env.CLERK_SECRET_KEY, publishableKey: env.CLERK_PUBLISHABLE_KEY, telemetry: { disabled: true } });
const relay = startRelay({
  origin: env.GHOSTIE_RELAY_ORIGIN, store, clients: env.GHOSTIE_OAUTH_CLIENTS,
  publishableKey: env.CLERK_PUBLISHABLE_KEY,
  clerkScriptURL: `${env.CLERK_FRONTEND_ORIGIN}/npm/@clerk/clerk-js@5/dist/clerk.browser.js`,
  sessionUser: async request => {
    try {
      const verified = await clerk.authenticateRequest(request, { acceptsToken: "session_token", authorizedParties: [env.GHOSTIE_RELAY_ORIGIN] });
      const auth = verified.toAuth();
      return auth?.userId && auth.sessionId ? auth.userId : null;
    } catch { return null; }
  },
});
process.on("SIGTERM", () => { relay.stop(); store.db.close(); process.exit(0); });
process.on("SIGINT", () => { relay.stop(); store.db.close(); process.exit(0); });
process.stdout.write("Ghostie relay started on loopback. TLS proxy required.\n");
