# Cloud Share — a link that lets a browser assistant reach your granted folders

OpenSheets' MCP server is a local program. Claude Code and Claude Desktop can spawn it; a page in a
browser tab cannot. Cloud Share is the answer to that: the app opens an outbound WebSocket to a
small hosted relay, and a link URL you hand to someone else routes MCP requests back down that
socket to a local `opensheets-mcp` subprocess on **your** Mac.

The relay routes bytes and grants nothing. Every grant check, the deny-list, the preview semantics,
the snapshot-before-write, and the untrusted-content envelope keep running exactly where they always
ran — in a local subprocess on the owner's machine, in the mode that cannot mint a grant.

> **Status, honestly.** The relay is deployed and answering
> (`https://opensheets-relay.opensheets-relay.workers.dev/health` → `{"ok":true}`), and the whole
> app-side stack — token, wire protocol, device identity, relay client, subprocess bridge, engine,
> service, and the GlassUI rows — is built and tested. **The Settings ▸ Cloud pane itself is not
> wired up yet**: nothing in `App/` renders those rows at this commit, so there is currently no
> button to click. `OSFlagCloudShare` also defaults off. Both are named as open gates in
> [DOCUMENTATION.md §12.1](../DOCUMENTATION.md#121-release-gates-that-are-genuinely-open). What
> follows describes the feature as designed and built; the owner flow in §4 is the flow the pane
> will drive, not a flow anyone has driven on a screen.

---

## 1. What a link grants, in one paragraph

A share link is a **capability URL**. It looks like
`https://<relay-host>/mcp/os1.<deviceId>.<secret>` and it carries 256 bits of entropy in the URL
*path* — never the query string, which the MCP specification prohibits for credentials. There are no
accounts, no passwords and no recipient-side setup: whoever holds the URL can use it, and the only
way to take it back is to revoke it.

A link has a **mode**. `read_only` is the default and exposes nine reading tools; `read_write`
exposes all 25. Mode is enforced on your Mac, not at the relay — a read-only link spawns the
subprocess with `--read-only`, so the write tools are not merely refused, they are never advertised
in `tools/list`.

---

## 2. Three sentences we will not soften

These are the honest limits. If any of them is unacceptable for your data, do not create a link.

1. **The relay terminates TLS, so your spreadsheet content transits it in plaintext per hop.** Both
   hops are encrypted — client→relay and relay→Mac are each TLS — but there is no end-to-end
   encryption between the AI client and your Mac. The relay sees decrypted frames as it forwards
   them. It is written to log no payloads and store no content, and that is a property of the code
   in `Relay/`, not a cryptographic guarantee.
2. **Anyone holding an active link can read — and on a read-write link edit — every workbook in
   every folder you have granted.** A link is not scoped more narrowly than your workspace grants.
   If you granted your whole Documents folder, that is what the link reaches. Grant narrowly first,
   then share.
3. **The relay stores only hashes and routes bytes.** Its Durable Object storage holds a device
   secret hash and a set of link-token hashes with a revoked flag — no plaintext token, no frame
   body, no filename, no cell.

---

## 3. The trust boundary — what actually changed, and what did not

[DOCUMENTATION.md §5.9](../DOCUMENTATION.md#59-client-compatibility) used to argue that a hosted
bridge was the wrong shape for this product. That argument is preserved there and answered there.
The short form, five points:

1. **The relay holds no credential that grants anything.** It cannot mint, widen or bypass a grant.
   A fully compromised relay can do exactly what a person holding a valid link can do, and nothing
   more — and only while the app is running with Cloud Share switched on.
2. **Revocation is enforced twice.** The relay rejects a revoked token hash on the fast path, and
   the app re-reads the link record from its database *per inbound request* and refuses to bridge a
   revoked one. A stale or malicious relay cannot resurrect a revoked link.
3. **The `SheetMCP` target still makes no network requests.** All networking lives in the app-side
   `SheetShare` target and the `Relay/` worker. `opensheets-mcp` remains a local stdio program that
   speaks newline-delimited JSON-RPC to a pipe; what changed is that the *app* may now pump that
   pipe to a socket, with your explicit, revocable, per-link consent.
4. **Off costs nothing, structurally.** With `OSFlagCloudShare` off, `AppModel.share` is `nil` — no
   service object exists. With the master toggle off, no engine is built: no socket, no Keychain
   read, no `share_link` query, no subprocess. Both are asserted by counting fakes in
   `CloudShareServiceTests`, not by prose.
5. **What we cannot promise, we say** — §2 above.

**Your own store is denied to the tools.** `~/Library/Application Support/OpenSheets` was added to
the standard deny-list when this feature landed, because share-link URLs are kept there in plaintext
next to the snapshots and the database. An agent reaching in through a link cannot read the links
that grant it, even if you granted `~/Library`. The three pre-existing deny-list tests were not
edited; the new assertion lives in `DenyListShareStoreTests`.

---

## 4. Creating a link (owner)

1. Settings (⌘,) → **Cloud**. Flip **Cloud Share** on. The status row goes `Connecting…` → `Online`.
   First enable generates the device identity: a device id in the local database, a 32-byte device
   secret in the macOS Keychain (service `com.quino.opensheets.cloud-share`).
2. Type a name in the create row — "Who is this for? e.g. Ana" — leave the mode at **Read only**, and
   click **Create & Copy**. The row appears and the full URL is on your clipboard.
3. Send the link to the person. Anyone who has it can use it, so treat it like a password: a chat
   message or an email carrying that URL is the credential.
4. The row's "Last used" updates as calls arrive.

**Revoking.** The row's context menu → **Revoke**. The row greys and shows `Revoked`; the relay
rejects the hash on its next request and the app refuses to bridge it regardless of what the relay
thinks. If your Mac is offline when you revoke, the local refusal is immediate and the relay learns
about it on the next reconnect — the revocation is never *waiting* on the network to take effect.
**Remove from list** deletes the record, and is only offered on an already-revoked link.

**Switching Cloud Share off** closes the socket and kills the subprocesses. Rows stay listed and the
links answer "offline" to callers until you switch it back on.

---

## 5. Adding a link (recipient)

The endpoint is **Streamable HTTP only**, at a non-`/sse` URL. There is no legacy SSE endpoint and
there will not be one. Every client below wants the URL pasted whole and the auth method set to
"none".

| Client | How | Auth setting | Verified? |
| --- | --- | --- | --- |
| **claude.ai** (personal) | Settings → Connectors → **Add custom connector** → paste the URL | **None** | Documented as supported; not driven on a screen |
| **ChatGPT** (web, Pro/Plus/Business/Enterprise/Edu) | Enable **Developer mode**, then Add MCP server → paste the URL | **No Authentication** | Documented as supported; not driven on a screen |
| **Gemini Enterprise** | Custom MCP server → paste the URL | **None** | Documented as supported; not driven on a screen |
| **Gemini** consumer (Spark custom apps) | Custom app → MCP server | unknown | **Unverified.** Whether the consumer surface accepts a no-auth server at all is not established |
| **claude.ai** under an org-managed admin flow | Admin adds the connector | may not offer "None" | **Unverified.** The org-managed flow may require an auth method we do not offer in v1 |

ChatGPT's developer mode allows write tools with a per-action confirmation, which pairs sensibly
with a `read_write` link. Claude's budgets are worth knowing when a workbook is large: tool calls get
300 s and results are capped near 150k characters. Our relay's own response timeout is 120 s, so the
relay gives up before the client does — you get an error, never a hang.

Sources for the table: claude.ai custom connectors
(`support.claude.com/en/articles/11175166`, `claude.com/docs/connectors/custom/remote-mcp`), ChatGPT
developer mode (`developers.openai.com/api/docs/guides/developer-mode`), Gemini Spark custom apps
(`support.google.com/gemini/answer/17209137`), Gemini Enterprise custom MCP
(`docs.cloud.google.com/gemini/enterprise/docs/connectors/custom-mcp-server`), and the Streamable
HTTP and Authorization specifications at `modelcontextprotocol.io`. Researched 2026-08-30 — client
UIs move, and a table of someone else's menu items is the first thing in this document to go stale.

**Sessions are decorative.** The relay mints an `Mcp-Session-Id` on `initialize` responses because
2025-era clients expect one, then ignores the header on every subsequent request and routes purely
by token. Nothing is built on session state, because MCP 2026-07-28 removes it.

---

## 6. What a read-only link can actually call

Nine tools, and the set is pinned whole by `EndToEndShareTests` rather than described here and
hoped for — a tool added to the read-only surface widens what every existing link can do, so it has
to fail a test rather than pass quietly:

`describe` · `find` · `get_selection` · `list_files` · `list_snapshots` · `list_workspace` ·
`open_in_app` · `read_range` · `reveal_range`

**`filter` and `snapshot` are deliberately absent, and people ask about both.** They read like
reading tools and they are not: `filter` takes an `action: "delete"` that removes the matching rows,
and `snapshot` writes a restore point. Neither annotation is a mistake, and the remedy — if a
read-only surface ought to list them — is to split the tool, not to special-case the filter. The
registry filters on each schema's own `isReadOnly` annotation and never on a list of names, so a
future tool classifies itself.

**Two of the nine touch your screen, not just your disk.** `open_in_app` brings OpenSheets forward
and opens a file; `reveal_range` selects a range in a window you are looking at. Both are read-only
with respect to the *file*, which is what the annotation means, but a recipient of a read-only link
can make your app come to the front. That is intended — it is how "show me the row you mean" works —
and it is worth knowing before you are surprised by it.

---

## 7. When your Mac is offline

Closed lid, quit app, no network, or Cloud Share switched off — all four look the same from the
outside. The relay waits, then answers the caller with a JSON-RPC error carrying the original
request's `id`:

> OpenSheets is offline on the owner's Mac. Ask them to open OpenSheets and check Settings → Cloud.

It is an error, never a hang, and never a silent empty result. On wake the app reconnects with
exponential backoff and re-sends its whole link set, which also heals the case where the database was
restored from a backup: links created after the backup stop working (the relay has never seen their
hashes) and links revoked after the backup are re-revoked.

---

## 8. Running your own relay

The relay in `Relay/` is a Cloudflare Worker with one Durable Object per device. Deploying it is a
user step, not something the app does:

```bash
cd Relay
npm ci
npm test            # 24 vitest cases, in the Workers runtime
npx wrangler login  # opens the browser for Cloudflare OAuth
npx wrangler deploy # prints the worker origin
```

`wrangler deploy` prints an origin like `https://opensheets-relay.<account>.workers.dev`. The app
compiles one in as `CloudShareConfiguration.standardRelayOrigin`; the `OSCloudRelayURL` user default
overrides it, which is how development against `wrangler dev` works. `Relay/README.md` is the
authoritative deploy note.

Tearing it down is the big red switch: `npx wrangler delete` kills every link at once, and every
caller gets the clean offline error from §7 rather than a timeout.

---

## 9. What is not verified

Stated plainly rather than rounded up, and repeated in
[DOCUMENTATION.md §12.1](../DOCUMENTATION.md#121-release-gates-that-are-genuinely-open):

- **The Settings ▸ Cloud pane is not wired up.** The GlassUI rows exist and their models are tested;
  no `App/` file renders them yet, so no human has created a link by clicking anything.
- **No link has been pasted into a real client.** The end-to-end suite drives a fake relay socket
  into the real subprocess against a real staged database, which proves the local stack. It does not
  prove that claude.ai's connector form accepts this URL.
- **Gemini's consumer surface (Spark custom apps) is unverified** for no-auth MCP servers.
- **The claude.ai org-managed admin flow may lack an auth-"None" option**, in which case an org-
  managed workspace cannot add a v1 link at all.
- **`OSFlagCloudShare` defaults off**, pending the two gates above.

The designed upgrade path for the auth question is relay-hosted OAuth 2.1 with a one-click consent
page bound to the link — no accounts, CIMD plus RFC 9728. It is designed and deliberately deferred:
an authless capability URL is the only shape that delivers zero recipient-side setup today, and the
mitigations are the ones in §1 through §3 — 256 bits in the path, revocation, last-used visibility,
read-only by default, off by default, hashes only at the relay.
