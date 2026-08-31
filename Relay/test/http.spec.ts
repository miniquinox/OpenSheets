import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { closeFromClient, connectAgent, makeDevice, postFrame, sayHello, tokenFor } from "./support";

describe("The HTTP surface answers exactly per wire contract B", () => {
  it("reports health", async () => {
    const response = await SELF.fetch("https://relay.test/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("answers 404 to a malformed token, whatever the method", async () => {
    for (const method of ["GET", "POST", "DELETE"]) {
      const response = await SELF.fetch("https://relay.test/mcp/not-a-token", { method });
      expect(response.status, method).toBe(404);
      expect(await response.text()).toBe("");
    }
  });

  it("answers 404 to a well-formed token nobody registered", async () => {
    const response = await postFrame(tokenFor(makeDevice("nobody")), '{"jsonrpc":"2.0","id":1,"method":"ping"}');
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("");
  });

  it("answers 405 to GET, 200 to DELETE, 204 to OPTIONS on a link URL", async () => {
    const token = tokenFor(makeDevice("methods"));
    expect((await SELF.fetch(`https://relay.test/mcp/${token}`)).status).toBe(405);
    expect((await SELF.fetch(`https://relay.test/mcp/${token}`, { method: "DELETE" })).status).toBe(200);
    expect((await SELF.fetch(`https://relay.test/mcp/${token}`, { method: "OPTIONS" })).status).toBe(204);
  });

  it("rejects an oversize frame with a -32000 body", async () => {
    const token = tokenFor(makeDevice("big"));
    const response = await postFrame(token, "x".repeat(4 * 1024 * 1024 + 1));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { error: { code: number; message: string } };
    expect(body.error.code).toBe(-32000);
    expect(body.error.message).toBe("Request exceeds 4 MB.");
  });

  it("answers the offline error, echoing the caller's id, when the Mac is gone", async () => {
    const device = makeDevice("offline");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);
    await closeFromClient(agent);

    const response = await postFrame(token, '{"jsonrpc":"2.0","id":42,"method":"tools/list"}');
    expect(response.status).toBe(200);
    const body = (await response.json()) as { id: number; error: { code: number; message: string } };
    expect(body.id).toBe(42);
    expect(body.error.code).toBe(-32000);
    expect(body.error.message).toContain("OpenSheets is offline");
  });

  it("round-trips a call through the agent socket", async () => {
    const device = makeDevice("roundtrip");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);

    const pending = postFrame(token, '{"jsonrpc":"2.0","id":7,"method":"tools/list"}');
    const request = await agent.next();
    expect(request.type).toBe("request");
    expect(request.linkId).toBe("L1");
    expect(request.expectsReply).toBe(true);
    expect(request.body).toBe('{"jsonrpc":"2.0","id":7,"method":"tools/list"}');
    agent.ws.send(
      JSON.stringify({
        body: '{"jsonrpc":"2.0","id":7,"result":{"tools":[]}}',
        requestId: request.requestId,
        status: "ok",
        type: "response",
      }),
    );
    const response = await pending;
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(await response.text()).toBe('{"jsonrpc":"2.0","id":7,"result":{"tools":[]}}');
    expect(response.headers.get("Mcp-Session-Id")).toBeNull();
  });

  it("mints a decorative Mcp-Session-Id on initialize responses", async () => {
    const device = makeDevice("session");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);

    const pending = postFrame(
      token,
      '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}',
    );
    const request = await agent.next();
    agent.ws.send(
      JSON.stringify({
        body: '{"jsonrpc":"2.0","id":0,"result":{}}',
        requestId: request.requestId,
        status: "ok",
        type: "response",
      }),
    );
    const response = await pending;
    expect(response.headers.get("Mcp-Session-Id")).toMatch(/[0-9a-f-]{36}/);
  });

  it("forwards a notification without awaiting and answers 202", async () => {
    const device = makeDevice("notify");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);

    const response = await postFrame(token, '{"jsonrpc":"2.0","method":"notifications/initialized"}');
    expect(response.status).toBe(202);
    const request = await agent.next();
    expect(request.type).toBe("request");
    expect(request.expectsReply).toBe(false);
  });

  it("times out an unanswered call into the offline error", async () => {
    const device = makeDevice("timeout");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);

    const response = await postFrame(token, '{"jsonrpc":"2.0","id":9,"method":"tools/list"}');
    const body = (await response.json()) as { id: number; error: { code: number } };
    expect(body.id).toBe(9);
    expect(body.error.code).toBe(-32000);
  });

  it("refuses a revoked link with the same 404 as an unknown one", async () => {
    const device = makeDevice("revoke");
    const token = tokenFor(device);
    const agent = await connectAgent(device);
    await sayHello(agent, device, [{ linkId: "L1", token }]);

    const { sha256Hex } = await import("../src/token");
    agent.ws.send(
      JSON.stringify({
        link: { linkId: "L1", revoked: true, tokenHash: await sha256Hex(token) },
        type: "link_upsert",
      }),
    );
    const ack = await agent.next();
    expect(ack).toEqual({ linkId: "L1", op: "link_upsert", type: "ack" });

    const response = await postFrame(token, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("");
  });

  it("treats the hello list as the whole truth — a link it omits is dead", async () => {
    const device = makeDevice("reconcile");
    const token = tokenFor(device);
    const first = await connectAgent(device);
    await sayHello(first, device, [{ linkId: "L1", token }]);
    await closeFromClient(first);

    const second = await connectAgent(device);
    await sayHello(second, device, []); // restored-from-backup Mac that never made L1
    const response = await postFrame(token, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    expect(response.status).toBe(404);
  });
});
