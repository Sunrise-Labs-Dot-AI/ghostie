#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const LIVE = process.argv.includes("--live");
const LIVE_BASE_URL = (process.env.DOWNLOAD_FLOW_BASE_URL || "https://messagesfor.ai").replace(/\/$/, "");
const DOWNLOAD_API = `${LIVE_BASE_URL}/api/download`;
const DOWNLOAD_PATH = "/releases/latest/download/Ghostie.dmg";
const LEGACY_DOWNLOAD_PATH = "/releases/latest/download/Messages-for-AI.dmg";

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), "utf8");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertNoPrivateGitHub(label, value) {
  assert(!/github\.com\/Sunrise-Labs-Dot-AI\/messages-for-ai\/releases/i.test(value), `${label} must not point at private GitHub Releases`);
}

function loadDownload() {
  const download = JSON.parse(read("download.json"));
  assert(/^v\d+\.\d+\.\d+(\.\d+)?$/.test(download.version), "download.json version must be a release tag");
  assert(Date.parse(download.publishedAt), "download.json publishedAt must parse");

  for (const key of ["dmg", "sparkleZip"]) {
    const artifact = download[key];
    assert(artifact && typeof artifact === "object", `download.json ${key} must exist`);
    assert(/^https:\/\//.test(artifact.url), `${key}.url must be HTTPS`);
    assertNoPrivateGitHub(`${key}.url`, artifact.url);
    assert(Number.isInteger(artifact.size) && artifact.size > 10_000_000, `${key}.size must look like a release artifact`);
    assert(/^[a-f0-9]{64}$/.test(artifact.sha256), `${key}.sha256 must be a sha256 hex digest`);
  }

  // DMG migrated to Ghostie.dmg. The legacy name is still accepted while the
  // live manifest is the pre-migration release; once a release republishes,
  // download.json carries Ghostie.dmg. Both download paths redirect (vercel.json).
  assert(
    download.dmg.name === "Ghostie.dmg" || download.dmg.name === "Messages-for-AI.dmg",
    "DMG filename must be Ghostie.dmg (legacy Messages-for-AI.dmg accepted during migration)"
  );
  assert(download.dmg.contentType === "application/x-apple-diskimage", "DMG content type must be application/x-apple-diskimage");
  assert(download.sparkleZip.name === `messages-for-ai-${download.version}.zip`, "Sparkle zip name must match version");
  assert(download.sparkleZip.contentType === "application/zip", "Sparkle zip content type must be application/zip");
  return download;
}

function newestAppcastItem(appcast) {
  const item = appcast.match(/<item>[\s\S]*?<\/item>/)?.[0];
  assert(item, "appcast.xml must contain at least one item");

  const title = item.match(/<title>([^<]+)<\/title>/)?.[1];
  const enclosure = item.match(/<enclosure\s+([^>]+)>/)?.[1];
  assert(title, "newest appcast item must have a title");
  assert(enclosure, "newest appcast item must have an enclosure");

  const attrs = {};
  for (const match of enclosure.matchAll(/([:\w]+)="([^"]*)"/g)) {
    attrs[match[1]] = match[2];
  }
  return { title, attrs };
}

function invokeDownloadHandler() {
  const handler = require(path.join(ROOT, "api/download.js"));
  const response = {
    headers: {},
    setHeader(key, value) {
      this.headers[key.toLowerCase()] = value;
    },
    end() {},
    status(code) {
      this.statusCode = code;
      return {
        json: (body) => {
          this.body = body;
        },
      };
    },
  };

  handler({ method: "GET" }, response);
  return response;
}

function checkStatic(download) {
  const appcast = newestAppcastItem(read("appcast.xml"));
  assert(appcast.title === download.version, "newest appcast item must match download.json version");
  assert(appcast.attrs.url === download.sparkleZip.url, "newest appcast enclosure URL must match download.json sparkleZip.url");
  assert(Number(appcast.attrs.length) === download.sparkleZip.size, "newest appcast enclosure length must match download.json sparkleZip.size");
  assert(appcast.attrs.type === "application/octet-stream", "Sparkle enclosure type must remain application/octet-stream");
  assert(appcast.attrs["sparkle:edSignature"], "Sparkle enclosure must include an EdDSA signature");
  assertNoPrivateGitHub("newest appcast enclosure", appcast.attrs.url);

  const vercel = JSON.parse(read("vercel.json"));
  const downloadRewrite = vercel.rewrites?.find((rewrite) => rewrite.source === DOWNLOAD_PATH);
  assert(downloadRewrite?.destination === "/api/download", "vercel.json must rewrite the Ghostie.dmg download path to /api/download");
  const legacyRewrite = vercel.rewrites?.find((rewrite) => rewrite.source === LEGACY_DOWNLOAD_PATH);
  assert(legacyRewrite?.destination === "/api/download", "vercel.json must keep redirecting the legacy Messages-for-AI.dmg path to /api/download");
  assert(!vercel.routes, "vercel.json must not use routes alongside headers");

  const sitePackage = JSON.parse(read("package.json"));
  assert(sitePackage.scripts?.["test:downloads"], "site/package.json must expose test:downloads");
  assert(sitePackage.scripts?.["test:downloads:live"], "site/package.json must expose test:downloads:live");

  const response = invokeDownloadHandler();
  assert(response.statusCode === 302, "api/download must return 302");
  assert(response.headers.location === download.dmg.url, "api/download must redirect to download.json dmg.url");
}

function head(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { method: "HEAD" }, (res) => {
      const statusCode = res.statusCode || 0;
      const location = res.headers.location;
      if ([301, 302, 303, 307, 308].includes(statusCode) && location && redirects < 5) {
        res.resume();
        resolve(head(new URL(location, url).toString(), redirects + 1));
        return;
      }
      res.resume();
      resolve({ statusCode, headers: res.headers, url });
    });
    req.setTimeout(20_000, () => req.destroy(new Error(`Timed out checking ${url}`)));
    req.on("error", reject);
    req.end();
  });
}

function text(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => {
        body += chunk;
      });
      res.on("end", () => resolve({ statusCode: res.statusCode || 0, body }));
    }).on("error", reject);
  });
}

function sha256(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if ((res.statusCode || 0) >= 400) {
        res.resume();
        reject(new Error(`${url} returned HTTP ${res.statusCode}`));
        return;
      }
      const hash = crypto.createHash("sha256");
      res.on("data", (chunk) => hash.update(chunk));
      res.on("end", () => resolve(hash.digest("hex")));
    }).on("error", reject);
  });
}

async function checkArtifact(label, artifact) {
  const response = await head(artifact.url);
  assert(response.statusCode === 200 || response.statusCode === 206, `${label} must be reachable`);
  assert(Number(response.headers["content-length"]) === artifact.size, `${label} content-length must match download.json`);
  const digest = await sha256(artifact.url);
  assert(digest === artifact.sha256, `${label} sha256 must match download.json`);
}

async function checkLive(download) {
  const redirected = await head(DOWNLOAD_API);
  assert(redirected.statusCode === 200 || redirected.statusCode === 206, "api/download must resolve to a downloadable artifact");
  assert(Number(redirected.headers["content-length"]) === download.dmg.size, "api/download content-length must match DMG size");

  await checkArtifact("DMG", download.dmg);
  await checkArtifact("Sparkle zip", download.sparkleZip);

  const liveAppcast = await text(`${LIVE_BASE_URL}/appcast.xml`);
  assert(liveAppcast.statusCode === 200, "live appcast.xml must return 200");
  const newest = newestAppcastItem(liveAppcast.body);
  assert(newest.title === download.version, "live newest appcast item must match download.json version");
  assert(newest.attrs.url === download.sparkleZip.url, "live newest appcast enclosure must match download.json sparkleZip.url");
}

(async () => {
  const download = loadDownload();
  checkStatic(download);
  if (LIVE) await checkLive(download);
  console.log(`download flow ok${LIVE ? " (live)" : ""}: ${download.version}`);
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
