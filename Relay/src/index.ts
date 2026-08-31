// The OpenSheets relay — a dumb pipe with a street address.
//
// Routes (wire contract B in .claude/plans/cloud-share-remote-mcp.md):
//   GET  /health          liveness
//   *    /agent           the Mac's outbound WebSocket (upgraded, then owned by ShareHub)
//   POST /mcp/<token>     one MCP JSON-RPC message in, one out
//   GET  /mcp/<token>     405 — no server-initiated stream is offered
//   DELETE /mcp/<token>   200 — client session cleanup, nothing to clean
//
// The worker validates shape and size; everything stateful lives in the
// per-device ShareHub Durable Object. Unknown, revoked, and malformed tokens
// all answer an identical empty 404 so the endpoint is not an oracle.

import { parseToken, sha256Hex } from "./token";

export interface Env {
  SHARE_HUB: DurableObjectNamespace;
  RESPONSE_TIMEOUT_MS?: string;
}

const MAXIMUM_REQUEST_BYTES = 4 * 1024 * 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    if (url.pathname === "/agent") {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response(null, { status: 426 });
      }
      const deviceId = request.headers.get("X-OpenSheets-Device") ?? "";
      const authorization = request.headers.get("Authorization") ?? "";
      if (!/^[A-Za-z0-9_-]{22}$/.test(deviceId) || !authorization.startsWith("Bearer ")) {
        return new Response(null, { status: 400 });
      }
      const hub = env.SHARE_HUB.get(env.SHARE_HUB.idFromName(deviceId));
      return hub.fetch(request);
    }

    if (url.pathname.startsWith("/mcp/")) {
      if (request.method === "OPTIONS") return new Response(null, { status: 204 });
      const parsed = parseToken(url.pathname.slice("/mcp/".length));
      if (parsed === null) return new Response(null, { status: 404 });
      if (request.method === "GET") return new Response(null, { status: 405 });
      if (request.method === "DELETE") return new Response(null, { status: 200 });
      if (request.method !== "POST") return new Response(null, { status: 405 });

      const body = await request.text();
      if (byteLength(body) > MAXIMUM_REQUEST_BYTES) {
        return new Response(
          JSON.stringify({
            jsonrpc: "2.0",
            id: null,
            error: { code: -32000, message: "Request exceeds 4 MB." },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }

      const tokenHash = await sha256Hex(parsed.token);
      const hub = env.SHARE_HUB.get(env.SHARE_HUB.idFromName(parsed.deviceId));
      return hub.fetch("https://share-hub.internal/internal/mcp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ tokenHash, body }),
      });
    }

    return new Response(null, { status: 404 });
  },
} satisfies ExportedHandler<Env>;

function byteLength(text: string): number {
  return new TextEncoder().encode(text).length;
}

export { ShareHub } from "./shareHub";
