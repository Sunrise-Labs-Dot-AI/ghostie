const download = require("../download.json");

module.exports = async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD");
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=86400");
  res.setHeader("Location", download.dmg.url);
  res.statusCode = 302;
  res.end();
};
