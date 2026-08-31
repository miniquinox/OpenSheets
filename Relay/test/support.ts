// Shared helpers for driving the relay the way the Mac app and the MCP
// clients do: an agent WebSocket per device, and plain HTTP posts per link.

import { SELF } from "cloudflare:test";
import { expect } from "vitest";
import { sha256Hex } from "../src/token";

export const SECRET_43 = "B".repeat(43);

/** A distinct, valid 22-char deviceId per test so DO state never bleeds. */
export function makeDevice(seed: string): string {
  return `D${seed}`.padEnd(22, "x").slice(0, 22);
}

export function tokenFor(device: string): string {
  return `os1.${device}.${SECRET_43}`;
}

export interface AgentConnection {
  ws: WebSocket;
  next: () => Promise<Record<string, unknown>>;
  closed: Promise<{ code: number }>;
}

export async function connectAgent(device: string, secret = "device-secret-1"): Promise<AgentConnection> {
  const response = await SELF.fetch("https://relay.test/agent", {
    headers: {
      Upgrade: "websocket",
      "X-OpenSheets-Device": device,
      Authorization: `Bearer ${secret}`,
    },
  });
  expect(response.status).toBe(101);
  const ws = response.webSocket!;
  const queue: Record<string, unknown>[] = [];
  const waiters: ((message: Record<string, unknown>) => void)[] = [];
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data as string) as Record<string, unknown>;
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else queue.push(message);
  });
  const closed = new Promise<{ code: number }>((resolve) => {
    ws.addEventListener("close", (event) => resolve({ code: event.code }));
  });
  ws.accept();
  return {
    ws,
    closed,
    next: () =>
      queue.length > 0
        ? Promise.resolve(queue.shift()!)
        : new Promise((resolve) => waiters.push(resolve)),
  };
}

export async function sayHello(
  agent: AgentConnection,
  device: string,
  links: { linkId: string; token: string; revoked?: boolean }[],
): Promise<void> {
  const wireLinks = [];
  for (const link of links) {
    wireLinks.push({
      linkId: link.linkId,
      revoked: link.revoked === true,
      tokenHash: await sha256Hex(link.token),
    });
  }
  agent.ws.send(
    JSON.stringify({ appVersion: "0.1.0", deviceId: device, links: wireLinks, type: "hello", v: 1 }),
  );
  const ack = await agent.next();
  expect(ack.type).toBe("hello_ack");
}

export function postFrame(token: string, body: string): Promise<Response> {
  return SELF.fetch(`https://relay.test/mcp/${token}`, { method: "POST", body });
}

/**
 * Close our own end and give the server a beat to process the close frame.
 * (A locally-initiated close does not reliably fire a local close event in
 * workerd, so awaiting `closed` after closing ourselves can hang.)
 */
export async function closeFromClient(agent: AgentConnection): Promise<void> {
  agent.ws.close(1000, "test done");
  await new Promise((resolve) => setTimeout(resolve, 100));
}
