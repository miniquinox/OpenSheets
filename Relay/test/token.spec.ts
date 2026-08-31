import { describe, expect, it } from "vitest";
import { parseToken, sha256Hex } from "../src/token";

const DEVICE = "AAAAAAAAAAAAAAAAAAAAAA"; // 22 chars
const SECRET = "B".repeat(43); // 43 chars
const TOKEN = `os1.${DEVICE}.${SECRET}`;

describe("A token is exactly os1.<22>.<43> in base64url", () => {
  it("parses the well-formed token and extracts the routing segment", () => {
    const parsed = parseToken(TOKEN);
    expect(parsed).not.toBeNull();
    expect(parsed!.deviceId).toBe(DEVICE);
    expect(parsed!.token).toBe(TOKEN);
  });

  it("hashes the shared test vector to the value the Swift suite pins", async () => {
    // ShareTokenTests in Packages/OpenSheetsCore pins the same pair.
    expect(await sha256Hex(TOKEN)).toBe(
      "75ce5756ee6c47791fe79a7812c0305e8b8e012496ad893247790f6c22392e1b",
    );
  });

  it("rejects every malformed shape", () => {
    expect(parseToken("")).toBeNull();
    expect(parseToken("os2." + DEVICE + "." + SECRET)).toBeNull();
    expect(parseToken("os1." + DEVICE.slice(1) + "." + SECRET)).toBeNull(); // short device
    expect(parseToken("os1." + DEVICE + "." + SECRET.slice(1))).toBeNull(); // short secret
    expect(parseToken(TOKEN + "x")).toBeNull(); // trailing garbage
    expect(parseToken("os1." + DEVICE + "." + SECRET + ".extra")).toBeNull();
    expect(parseToken("os1." + "?".repeat(22) + "." + SECRET)).toBeNull(); // invalid chars
    expect(parseToken(TOKEN.toUpperCase() === TOKEN ? "os1..": "os1..")).toBeNull(); // empty segments
  });

  it("computes standard SHA-256 (empty-string vector)", async () => {
    expect(await sha256Hex("")).toBe(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
  });
});
