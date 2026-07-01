// Shared business / non-person detector — the single source of truth for "is
// this counterparty a business?" across the metadata-only product services
// (Keep Tabs recommendations, Birthday seed, Texting Wrapped analytics). It
// mirrors the HANDLE + NAME layers of the Don't Ghost filter
// (menubar/Sources/MessagesForAIMenu/DontGhostController.swift) so a user never
// has to sort through or dismiss a business that one surface filters and another
// doesn't. Keep the two lists in sync (same dual-impl discipline as canonHandle).
//
// Two layers, both metadata-safe (handle + Contacts name only — NO message
// bodies, so the privacy posture of the metadata-only services is unchanged):
//   • handle  — shortcodes, toll-free, alpha senders (via counterpartyClass),
//                plus no-reply / notification email addresses.
//   • name    — business-name tokens (brands + generic business nouns + health),
//                matched on WORD BOUNDARIES so a surname like "Banks" or "Healey"
//                is never mistaken for "bank" / "health".
//
// Don't Ghost adds a third, CONTENT-based layer (automated/transactional body
// detection — e.g. a clinic reminder from a plain phone number). That layer needs
// message bodies and deliberately stays in Don't Ghost; the metadata-only
// services rely on handle + name, which catches every business that has a
// business-y handle or a saved business name (the common case).

// Toll-free North American area codes — a number in one of these is a business
// line, never a personal mobile.
const TOLLFREE_NPAS = new Set(["800", "833", "844", "855", "866", "877", "888"]);

export type CounterpartyClass = "person" | "shortcode" | "tollfree" | "alpha";

// Classify a counterparty by its handle SHAPE alone: a 3–6 digit shortcode, a
// toll-free number, an alpha sender (letters), or a person. Lives here as the
// base layer of business detection; re-exported by analyze.ts for back-compat.
export function counterpartyClass(senderKey: string | null | undefined): CounterpartyClass {
  if (!senderKey || senderKey.includes("@")) return "person";
  const digits = senderKey.replace(/^\+/, "");
  if (/^\d+$/.test(digits)) {
    if (digits.length >= 3 && digits.length <= 6) return "shortcode";
    const npa = digits.length === 11 && digits[0] === "1" ? digits.slice(1, 4) : digits.slice(0, 3);
    return TOLLFREE_NPAS.has(npa) ? "tollfree" : "person";
  }
  if (/[A-Za-z]/.test(senderKey)) return "alpha";
  return "person";
}

// Business-name tokens. Mirrors Don't Ghost's isObviousBusinessName, extended
// with the health ("One Medical" class), finance, travel, and telecom names that
// most often slip in as a saved contact. Distinctive brand names are safe as-is;
// generic nouns ("bank", "delta") are only risky as substrings, which the
// word-boundary match below neutralizes. Multi-word phrases are matched verbatim.
export const BUSINESS_NAME_TOKENS: readonly string[] = [
  // delivery / commerce
  "doordash", "door dash", "ubereats", "uber", "lyft", "amazon", "instacart",
  "grubhub", "postmates", "shipt", "ups", "fedex", "usps", "dhl",
  // finance
  "bank", "chase", "wells fargo", "bank of america", "amex", "american express",
  "paypal", "venmo", "capital one", "billing", "receipt", "invoice", "payment",
  "mortgage", "insurance", "geico", "state farm",
  // security / automated / notifications
  "alert", "alerts", "verification", "verify", "otp", "security code",
  "verification code", "your code", "do not reply", "no reply", "noreply",
  "donotreply", "notification", "notifications", "unsubscribe",
  // travel / reservations
  "airbnb", "vrbo", "delta", "united", "southwest", "jetblue",
  "american airlines", "marriott", "hilton", "reservation", "booking",
  // health (the One Medical class)
  "one medical", "medical", "clinic", "pharmacy", "cvs", "walgreens", "dentist",
  "dental", "doctor", "hospital", "urgent care", "healthcare", "kaiser",
  "labcorp", "quest diagnostics",
  // services / appointments
  "appointment", "salon", "spa", "support", "customer service", "tech support",
  "warranty",
  // telecom / utility
  "verizon", "t-mobile", "comcast", "xfinity", "spectrum",
];

// no-reply / notification email local-parts and brands that mark an email
// address as automated rather than a person. counterpartyClass treats every
// email as a person, so this is the email gap it misses.
const NO_REPLY_EMAIL_TOKENS: readonly string[] = [
  "no-reply", "noreply", "no_reply", "donotreply", "do-not-reply", "notifications",
  "notification", "alerts", "alert", "support", "billing", "receipt", "receipts",
  "info@", "hello@", "mailer", "no.reply", "account-update",
  "rbm.goog", // Google Rich Business Messaging — every @rbm.goog sender is a verified business
];

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// One word-boundary alternation over every name token, built once.
const BUSINESS_NAME_RE = new RegExp(
  "\\b(" + BUSINESS_NAME_TOKENS.map(escapeRegExp).join("|") + ")\\b",
  "i",
);

// A saved Contacts name that names a business rather than a person.
export function looksLikeBusinessName(name: string | null | undefined): boolean {
  if (!name) return false;
  return BUSINESS_NAME_RE.test(name);
}

// A handle (phone / email / sender id) that belongs to a business: a shortcode,
// toll-free number, alpha sender, or a no-reply/notification email.
export function looksLikeBusinessHandle(handle: string | null | undefined): boolean {
  if (!handle) return false;
  const lowered = handle.toLowerCase();
  if (lowered.includes("@")) {
    return NO_REPLY_EMAIL_TOKENS.some((t) => lowered.includes(t));
  }
  return counterpartyClass(handle) !== "person";
}

// True when the counterparty is a business by EITHER its handle or its saved
// name. The single check every metadata-only service should call before
// presenting a contact to the user.
export function looksLikeBusiness(
  handle: string | null | undefined,
  name: string | null | undefined,
): boolean {
  return looksLikeBusinessHandle(handle) || looksLikeBusinessName(name);
}
