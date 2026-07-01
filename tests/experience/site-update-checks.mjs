#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));

function fail(message) {
  throw new Error(message);
}

function read(path) {
  return readFileSync(resolve(root, path), "utf8");
}

const appcast = read("site/appcast.xml");
const releases = [...appcast.matchAll(/<item\b[\s\S]*?<\/item>/g)].map((match) => match[0]);
if (!releases.length) fail("site/appcast.xml has no releases");

let previous = Infinity;
for (const item of releases) {
  const title = item.match(/<title>([^<]+)<\/title>/)?.[1] ?? "unknown release";
  const version = Number(item.match(/<sparkle:version>(\d+)<\/sparkle:version>/)?.[1]);
  const url = item.match(/url="([^"]+)"/)?.[1] ?? "";
  const signature = item.match(/sparkle:edSignature="([^"]+)"/)?.[1] ?? "";
  const length = Number(item.match(/length="(\d+)"/)?.[1]);
  if (!Number.isInteger(version) || version <= 0) {
    fail(`invalid Sparkle version for ${title}`);
  }
  if (version >= previous) {
    fail(`Sparkle versions must be strictly descending; saw ${version} after ${previous}`);
  }
  previous = version;
  if (!url.startsWith("https://")) {
    fail(`release ${title} has a non-HTTPS enclosure URL`);
  }
  if (!signature) {
    fail(`release ${title} is missing sparkle:edSignature`);
  }
  if (!(length > 1_000_000)) {
    fail(`release ${title} has an implausible asset length`);
  }
}

const control = JSON.parse(read("site/control.json"));
if (!control.min_supported_version) fail("control.json missing min_supported_version");
if (!control.issued_at) fail("control.json missing issued_at");
if (!read("site/control.json.sig").trim()) fail("control.json.sig is empty");

for (const page of ["site/privacy.html", "site/security.html", "site/terms.html"]) {
  const html = read(page);
  for (const phrase of ["Messages for AI", "WhatsApp"]) {
    if (!html.includes(phrase)) fail(`${page} missing ${phrase}`);
  }
}

const privacy = read("site/privacy.html");
for (const phrase of [
  "Product analytics never include message bodies",
  "When models may receive content",
  "Locally cached WhatsApp message content is encrypted",
]) {
  if (!privacy.includes(phrase)) fail(`privacy page missing required claim: ${phrase}`);
}

console.log(`ok appcast/site/control metadata: ${releases.length} releases`);
