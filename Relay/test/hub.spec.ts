import { describe, expect, it } from "vitest";
import { closeFromClient, connectAgent, makeDevice, sayHello, tokenFor } from "./support";

describe("The agent socket authenticates before it routes", () => {
  it("acks a first hello and remembers the secret (trust on first use)", async () => {
    const device = makeDevice("tofu");
    const agent = await connectAgent(device, "secret-one");
    await sayHello(agent, device, []);
    await closeFromClient(agent);

    const again = await connectAgent(device, "secret-one");
    await sayHello(again, device, []); // same secret reconnects fine
  });

  it("closes 4401 when a different secret claims a registered device", async () => {
    const device = makeDevice("intruder");
    const owner = await connectAgent(device, "owner-secret");
    await sayHello(owner, device, []);
    await closeFromClient(owner);

    const intruder = await connectAgent(device, "not-the-secret");
    intruder.ws.send(
      JSON.stringify({ appVersion: "0.1.0", deviceId: device, links: [], type: "hello", v: 1 }),
    );
    const refusal = await intruder.next();
    expect(refusal).toEqual({ code: "auth_failed", type: "error" });
    expect((await intruder.closed).code).toBe(4401);
  });

  it("closes 4401 when the hello names a different device than the connection", async () => {
    const device = makeDevice("mismatch");
    const agent = await connectAgent(device);
    agent.ws.send(
      JSON.stringify({
        appVersion: "0.1.0",
        deviceId: makeDevice("someoneelse"),
        links: [],
        type: "hello",
        v: 1,
      }),
    );
    const refusal = await agent.next();
    expect(refusal).toEqual({ code: "auth_failed", type: "error" });
    expect((await agent.closed).code).toBe(4401);
  });

  it("closes 4401 when the first message is not a hello", async () => {
    const device = makeDevice("nohello");
    const agent = await connectAgent(device);
    agent.ws.send(
      JSON.stringify({
        link: { linkId: "L1", revoked: false, tokenHash: "0".repeat(64) },
        type: "link_upsert",
      }),
    );
    const refusal = await agent.next();
    expect(refusal).toEqual({ code: "auth_failed", type: "error" });
    expect((await agent.closed).code).toBe(4401);
  });

  it("ignores unknown message types instead of dying", async () => {
    const device = makeDevice("unknown");
    const agent = await connectAgent(device);
    await sayHello(agent, device, []);
    agent.ws.send(JSON.stringify({ type: "from_the_future", shiny: true }));
    agent.ws.send("not json at all");
    // The socket is still alive and useful afterwards:
    await sayHello(agent, device, [{ linkId: "L1", token: tokenFor(device) }]);
  });

  it("answers the 30-second ping without waking application code", async () => {
    const device = makeDevice("ping");
    const agent = await connectAgent(device);
    await sayHello(agent, device, []);
    agent.ws.send(JSON.stringify({ type: "ping" }));
    const pong = await agent.next();
    expect(pong).toEqual({ type: "pong" });
  });

  it("refuses an upgrade without device headers", async () => {
    const { SELF } = await import("cloudflare:test");
    const response = await SELF.fetch("https://relay.test/agent", {
      headers: { Upgrade: "websocket" },
    });
    expect(response.status).toBe(400);
  });

  it("refuses a plain GET to /agent", async () => {
    const { SELF } = await import("cloudflare:test");
    const response = await SELF.fetch("https://relay.test/agent");
    expect(response.status).toBe(426);
  });
});
