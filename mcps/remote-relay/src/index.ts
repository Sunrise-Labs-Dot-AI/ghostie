import { createClerkClient } from "@clerk/backend";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { Store } from "./store.ts";
import { startRelay } from "./server.ts";
import { relayConfigSchema } from "./config.ts";
import { createMessageLinkCreator } from "./message-opener.ts";

const config = relayConfigSchema.safeParse(process.env);
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
  messageLinks: createMessageLinkCreator({ token: env.MESSAGE_OPENER_API_TOKEN, endpoint: env.MESSAGE_OPENER_API_URL }),
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
