import { rewrite } from "@vercel/edge";

// Host-based routing. vercel.json rewrites cannot serve per-host pages when
// a same-path filesystem route exists; Edge Middleware runs before filesystem.
const HOST_ROUTES = new Map([
  ["ghostie.app", new Map([
    ["/", "/ghostie/index.html"],
    ["/pro", "/ghostie/pro.html"],
    ["/privacy", "/ghostie/privacy/index.html"],
    ["/privacy.html", "/ghostie/privacy/index.html"],
    ["/terms", "/ghostie/terms/index.html"],
    ["/terms.html", "/ghostie/terms/index.html"],
    ["/security", "/ghostie/security/index.html"],
    ["/security.html", "/ghostie/security/index.html"],
    ["/support", "/ghostie/support/index.html"],
    ["/support.html", "/ghostie/support/index.html"]
  ])],
  ["www.ghostie.app", new Map([
    ["/", "/ghostie/index.html"],
    ["/pro", "/ghostie/pro.html"],
    ["/privacy", "/ghostie/privacy/index.html"],
    ["/privacy.html", "/ghostie/privacy/index.html"],
    ["/terms", "/ghostie/terms/index.html"],
    ["/terms.html", "/ghostie/terms/index.html"],
    ["/security", "/ghostie/security/index.html"],
    ["/security.html", "/ghostie/security/index.html"],
    ["/support", "/ghostie/support/index.html"],
    ["/support.html", "/ghostie/support/index.html"]
  ])],
  ["textingwrapped.com", new Map([
    ["/", "/texting-wrapped/index.html"]
  ])],
  ["www.textingwrapped.com", new Map([
    ["/", "/texting-wrapped/index.html"]
  ])]
]);

export const config = {
  matcher: [
    "/",
    "/pro/:path*",
    "/privacy/:path*",
    "/privacy.html",
    "/terms/:path*",
    "/terms.html",
    "/security/:path*",
    "/security.html",
    "/support/:path*",
    "/support.html"
  ]
};

export default function middleware(request) {
  const host = (request.headers.get("host") || "").toLowerCase();
  const url = new URL(request.url);
  const routes = HOST_ROUTES.get(host);
  const path = url.pathname.replace(/\/$/, "") || "/";
  const destination = routes?.get(path);
  if (!destination) return; // primary site and previews: normal routing
  return rewrite(new URL(destination, request.url));
}
