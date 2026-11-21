// Cloudflare Worker that keeps the Gemini key off the phone.
// The app sends requests here with a shared app token; the Worker adds the real key.
// Rotate the token any time, and add rate limits in the Cloudflare dashboard.
//
// Deploy:
//   npm create cloudflare@latest sightsense-proxy   (choose "Hello World" Worker), replace src/index.js with this file
//   npx wrangler secret put GEMINI_API_KEY
//   npx wrangler secret put APP_TOKEN
//   npx wrangler deploy
// Then set GEMINI_PROXY_HOST and GEMINI_APP_TOKEN in Config/Secrets.xcconfig.

const ALLOWED = /^\/v1beta\/models\/[\w.-]+:(generateContent|streamGenerateContent)$/;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
    if (!env.APP_TOKEN || request.headers.get("x-app-token") !== env.APP_TOKEN) {
      return new Response("Forbidden", { status: 403 });
    }
    const url = new URL(request.url);
    if (!ALLOWED.test(url.pathname)) return new Response("Not found", { status: 404 });

    const upstream = new URL(url.pathname + url.search, "https://generativelanguage.googleapis.com");
    return fetch(upstream, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
      body: request.body,
    });
  },
};
