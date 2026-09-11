#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const analytics = fs.readFileSync(path.join(ROOT, "analytics.js"), "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(analytics.includes('posthog.capture("download_click"'), "analytics.js must capture download_click");
assert(analytics.includes('posthog.capture("tip_opened"'), "analytics.js must capture tip_opened");
assert(analytics.includes('posthog.capture("tip_completed"'), "analytics.js must capture tip_completed");
assert(!/tip_amount|unit_amount|amount_cents/.test(analytics), "analytics.js must not send tip amounts");
assert(
  /posthog\.capture\("tip_completed",\s*\{\s*page: location\.pathname\s*\}\)/.test(analytics),
  "tip_completed must send only the page path"
);
assert(analytics.includes("autocapture: false"), "analytics.js must keep autocapture off");
assert(analytics.includes("disable_session_recording: true"), "analytics.js must keep session recording off");

const privacy = fs.readFileSync(path.join(ROOT, "privacy.html"), "utf8");
assert(privacy.includes("tip-jar opened or completed"), "privacy.html must disclose tip-jar events");
assert(privacy.includes("no tip amounts"), "privacy.html must say tip amounts are not collected");

console.log("analytics.js tip + download capture checks passed");
