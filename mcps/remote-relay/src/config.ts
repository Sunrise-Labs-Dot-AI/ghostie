import { z } from "zod";
import { oauthRedirectURI } from "./authorization.ts";

const httpsOrigin = z.string().url().refine(value => {
  const url = new URL(value);
  return url.protocol === "https:" && url.origin === value && !url.username && !url.password;
});

export const relayConfigSchema = z.object({
  GHOSTIE_RELAY_ORIGIN: httpsOrigin,
  CLERK_PUBLISHABLE_KEY: z.string().regex(/^pk_(test|live)_/),
  CLERK_SECRET_KEY: z.string().regex(/^sk_(test|live)_/),
  CLERK_FRONTEND_ORIGIN: httpsOrigin,
  GHOSTIE_RELAY_DB: z.string().min(1),
  GHOSTIE_OAUTH_CLIENTS: z.string().transform(value => JSON.parse(value)).pipe(z.array(z.object({
    id: z.string().min(1).max(200), name: z.string().min(1).max(100),
    redirects: z.array(oauthRedirectURI).min(1),
  }).strict()).min(1)),
  MESSAGE_OPENER_API_TOKEN: z.string().min(32).max(8_192),
  GHOSTIE_CONTAINER_SMOKE: z.literal("1").optional(),
  MESSAGE_OPENER_API_URL: z.literal("http://opener.test:8788/v1/links").optional(),
}).superRefine((value, context) => {
  if ((value.GHOSTIE_CONTAINER_SMOKE === "1") !== Boolean(value.MESSAGE_OPENER_API_URL)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Container smoke configuration is incomplete" });
  }
});
