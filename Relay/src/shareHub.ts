// ShareHub — one Durable Object per device (id = the token's deviceId segment).
//
// It does exactly two things:
//   1. Holds the device's agent WebSocket (the Mac dials out; wire contract A).
//   2. Forwards MCP frames from link URLs down that socket and returns the
//      response (wire contract B).
//
// Storage holds only `secretHash` (TOFU device auth) and `link:<tokenHashHex>`
// rows `{linkId, revoked}`. No payloads, no tokens, no content — logging is
// ids only, on purpose.
//
// Contracts are normative in .claude/plans/cloud-share-remote-mcp.md.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./index";

interface StoredLink {
  linkId: string;
  revoked: boolean;
}

interface Attachment {
  deviceId: string;
  secretHash: string;
  authed: boolean;
}

interface PendingRequest {
  resolve: (outcome: { status: "ok" | "error"; body?: string }) => void;
  timer: ReturnType<typeof setTimeout>;
}

const OFFLINE_MESSAGE =
  "OpenSheets is offline on the owner's Mac. Ask them to open OpenSheets and check Settings → Cloud.";

/** The exact offline/error JSON-RPC body, echoing the caller's id (wire contract B). */
export function offlineError(id: unknown): string {
  return JSON.stringify({
    jsonrpc: "2.0",
    id: id === undefined ? null : id,
    error: { code: -32000, message: OFFLINE_MESSAGE },
  });
}

export class ShareHub extends DurableObject<Env> {
  private pending = new Map<string, PendingRequest>();

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/agent") return this.acceptAgent(request);
    if (url.pathname === "/internal/mcp" && request.method === "POST") {
      const { tokenHash, body } = (await request.json()) as { tokenHash: string; body: string };
      return this.routeFrame(tokenHash, body);
    }
    return new Response(null, { status: 404 });
  }

  // MARK: agent socket (wire contract A)

  private async acceptAgent(request: Request): Promise<Response> {
    const deviceId = request.headers.get("X-OpenSheets-Device") ?? "";
    const authorization = request.headers.get("Authorization") ?? "";
    const secret = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
    if (deviceId === "" || secret === "") return new Response(null, { status: 400 });

    const secretHash = await sha256HexLocal(secret);
    const pair = new WebSocketPair();
    const attachment: Attachment = { deviceId, secretHash, authed: false };
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment(attachment);
    // The app pings every 30 s; answering from here keeps hibernation cheap.
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair(JSON.stringify({ type: "ping" }), JSON.stringify({ type: "pong" })),
    );
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return; // frames are single-line JSON text
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(message) as Record<string, unknown>;
    } catch {
      return; // unknown/garbled messages are ignored (forward compatibility)
    }
    const attachment = ws.deserializeAttachment() as Attachment;

    if (parsed.type === "hello") {
      await this.handleHello(ws, attachment, parsed);
      return;
    }
    if (!attachment.authed) {
      // hello is the mandatory first message; anything else is an auth failure.
      this.refuse(ws);
      return;
    }
    switch (parsed.type) {
      case "link_upsert": {
        const link = parsed.link as { linkId?: string; tokenHash?: string; revoked?: boolean } | undefined;
        if (!link || typeof link.tokenHash !== "string" || typeof link.linkId !== "string") return;
        await this.ctx.storage.put(`link:${link.tokenHash}`, {
          linkId: link.linkId,
          revoked: link.revoked === true,
        } satisfies StoredLink);
        ws.send(JSON.stringify({ linkId: link.linkId, op: "link_upsert", type: "ack" }));
        console.log(`link_upsert device=${attachment.deviceId} link=${link.linkId}`);
        return;
      }
      case "response": {
        const requestId = parsed.requestId;
        if (typeof requestId !== "string") return;
        const waiting = this.pending.get(requestId);
        if (waiting === undefined) return; // late response after timeout — drop
        this.pending.delete(requestId);
        clearTimeout(waiting.timer);
        if (parsed.status === "ok" && typeof parsed.body === "string") {
          waiting.resolve({ status: "ok", body: parsed.body });
        } else {
          waiting.resolve({ status: "error" });
        }
        return;
      }
      default:
        return; // unknown types are ignored (forward compatibility)
    }
  }

  private async handleHello(ws: WebSocket, attachment: Attachment, hello: Record<string, unknown>): Promise<void> {
    const stored = await this.ctx.storage.get<string>("secretHash");
    const declaredDevice = typeof hello.deviceId === "string" ? hello.deviceId : "";
    if (declaredDevice !== attachment.deviceId || (stored !== undefined && stored !== attachment.secretHash)) {
      this.refuse(ws);
      return;
    }
    if (stored === undefined) {
      // Trust on first use: the DO id is 128-bit random, unguessable before registration.
      await this.ctx.storage.put("secretHash", attachment.secretHash);
    }

    // The hello list replaces the link table — reconciliation heals backup-restore drift.
    const existing = await this.ctx.storage.list({ prefix: "link:" });
    await this.ctx.storage.delete([...existing.keys()]);
    const links = Array.isArray(hello.links) ? (hello.links as unknown[]) : [];
    for (const entry of links) {
      const link = entry as { linkId?: string; tokenHash?: string; revoked?: boolean };
      if (typeof link.tokenHash !== "string" || typeof link.linkId !== "string") continue;
      await this.ctx.storage.put(`link:${link.tokenHash}`, {
        linkId: link.linkId,
        revoked: link.revoked === true,
      } satisfies StoredLink);
    }

    attachment.authed = true;
    ws.serializeAttachment(attachment);
    ws.send(JSON.stringify({ type: "hello_ack", v: 1 }));
    console.log(`hello device=${attachment.deviceId} links=${links.length}`);
  }

  private refuse(ws: WebSocket): void {
    ws.send(JSON.stringify({ code: "auth_failed", type: "error" }));
    ws.close(4401, "auth_failed");
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    // In-flight calls die with the socket; fail them fast rather than waiting out the timer.
    for (const [, waiting] of this.pending) {
      clearTimeout(waiting.timer);
      waiting.resolve({ status: "error" });
    }
    this.pending.clear();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  // MARK: frame routing (wire contract B)

  private async routeFrame(tokenHash: string, body: string): Promise<Response> {
    const link = await this.ctx.storage.get<StoredLink>(`link:${tokenHash}`);
    // Unknown and revoked answer identically — the 404 must not be an oracle.
    if (link === undefined || link.revoked) return new Response(null, { status: 404 });

    // A frame without an id (or with a null id) is a notification: forwarded,
    // never awaited, answered 202. An unparseable frame is forwarded and awaited —
    // the server responds to those with a parse error carrying id null.
    let frameId: unknown;
    let expectsReply: boolean;
    let isInitialize = false;
    try {
      const frame = JSON.parse(body) as Record<string, unknown>;
      frameId = frame.id;
      expectsReply = frame.id !== undefined && frame.id !== null;
      isInitialize = frame.method === "initialize";
    } catch {
      frameId = null;
      expectsReply = true;
    }

    const socket = this.liveSocket();
    if (socket === null) {
      if (!expectsReply) return new Response(null, { status: 202 });
      return jsonResponse(offlineError(frameId));
    }

    const requestId = crypto.randomUUID();
    socket.send(
      JSON.stringify({ body, expectsReply, linkId: link.linkId, requestId, type: "request" }),
    );
    console.log(`request device link=${link.linkId} request=${requestId} reply=${expectsReply}`);
    if (!expectsReply) return new Response(null, { status: 202 });

    const timeoutMs = Number(this.env.RESPONSE_TIMEOUT_MS ?? "120000");
    const outcome = await new Promise<{ status: "ok" | "error"; body?: string }>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        resolve({ status: "error" });
      }, timeoutMs);
      this.pending.set(requestId, { resolve, timer });
    });

    if (outcome.status !== "ok" || outcome.body === undefined) {
      return jsonResponse(offlineError(frameId));
    }
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (isInitialize) {
      // 2025-era clients expect a session id on initialize; routing ignores it (D9).
      headers["Mcp-Session-Id"] = crypto.randomUUID();
    }
    return new Response(outcome.body, { status: 200, headers });
  }

  private liveSocket(): WebSocket | null {
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment | null;
      if (attachment?.authed === true) return ws;
    }
    return null;
  }
}

function jsonResponse(body: string): Response {
  return new Response(body, { status: 200, headers: { "content-type": "application/json" } });
}

async function sha256HexLocal(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
