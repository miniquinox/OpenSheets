// Share tokens — decision D5 in .claude/plans/cloud-share-remote-mcp.md.
//
// Format: os1.<deviceId>.<secret>
//   deviceId = 22 chars of base64url (16 random bytes, minted by the app)
//   secret   = 43 chars of base64url (32 random bytes, minted by the app)
//
// The relay never stores a token in plaintext: it routes on the deviceId
// segment and authenticates by comparing SHA-256(full token) against the
// hashes the app registered over its agent socket.
//
// Shared test vector — the Swift suite (ShareTokenTests) pins the same pair:
//   token  = "os1.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
//   sha256 = "75ce5756ee6c47791fe79a7812c0305e8b8e012496ad893247790f6c22392e1b"

const TOKEN_PATTERN = /^os1\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/;

export interface ParsedToken {
  /** The routing segment — names the Durable Object, not a secret by itself. */
  deviceId: string;
  /** The full token as received; only its hash is ever stored or compared. */
  token: string;
}

/** Returns null for anything that is not exactly a well-formed os1 token. */
export function parseToken(segment: string): ParsedToken | null {
  const match = TOKEN_PATTERN.exec(segment);
  return match ? { deviceId: match[1], token: segment } : null;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
