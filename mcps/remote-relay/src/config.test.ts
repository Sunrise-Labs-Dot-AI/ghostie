import { expect, test } from "bun:test";
import { relayConfigSchema } from "./config.ts";

const fixture = {
  GHOSTIE_RELAY_ORIGIN: "https://relay.example.test",
  CLERK_PUBLISHABLE_KEY: "pk_test_fixture",
  CLERK_SECRET_KEY: "sk_test_fixture",
  CLERK_FRONTEND_ORIGIN: "https://clerk.example.test",
  GHOSTIE_RELAY_DB: ":memory:",
  GHOSTIE_OAUTH_CLIENTS: '[{"id":"fixture","name":"Fixture","redirects":["https://client.example.test/callback"]}]',
  MESSAGE_OPENER_API_TOKEN: "synthetic-opener-token-that-is-long-enough",
};

test("relay configuration requires a server-only opener token", () => {
  expect(relayConfigSchema.safeParse(fixture).success).toBe(true);
  const { MESSAGE_OPENER_API_TOKEN: _removed, ...missing } = fixture;
  const parsed = relayConfigSchema.safeParse(missing);
  expect(parsed.success).toBe(false);
  expect(JSON.stringify(parsed)).not.toContain(fixture.MESSAGE_OPENER_API_TOKEN);
});

test("only the exact container-smoke endpoint can replace the production opener", () => {
  expect(relayConfigSchema.safeParse({ ...fixture, GHOSTIE_CONTAINER_SMOKE: "1", MESSAGE_OPENER_API_URL: "http://opener.test:8788/v1/links" }).success).toBe(true);
  expect(relayConfigSchema.safeParse({ ...fixture, MESSAGE_OPENER_API_URL: "http://opener.test:8788/v1/links" }).success).toBe(false);
  expect(relayConfigSchema.safeParse({ ...fixture, GHOSTIE_CONTAINER_SMOKE: "1", MESSAGE_OPENER_API_URL: "https://evil.example.test/v1/links" }).success).toBe(false);
});
