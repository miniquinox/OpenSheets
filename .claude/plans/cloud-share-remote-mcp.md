# Cloud Share — one-click remote MCP access through a hosted relay

**Goal.** A "Cloud" section in Settings with a Share button. Creating a share link mints an
authenticated URL the owner can hand to anyone; pasting that URL into claude.ai (custom
connector), ChatGPT (developer mode), or Gemini as a remote MCP server gives that assistant
access to the owner's granted OpenSheets workbooks with zero recipient-side setup. The owner
sees every issued link (name, mode, created, last used) and can revoke any of them instantly.
The Mac remains the only place authority lives: the relay routes bytes, it grants nothing.

**This feature reverses a stated non-goal.** `README.md:35` ("A hosted bridge to your local
files for browser-based assistants"), `DOCUMENTATION.md:1236-1264` (§5.9, "The server is
stdio-only … shipping it by accident under the same name would be worse than not shipping
it"), and `PLAN.md:8` ("no cloud") all argue against this. The repo's own precedent for
inverting a narrative is `.claude/plans/connect-to-claude-one-click.md:43-53` ("The policy
line this feature must draw") and `DOCUMENTATION.md` §9.5: redraw the line explicitly in the
docs, keep the tests that pin the old boundary passing **untouched**, and name which
invariant moved and which did not. This plan does that in "The policy line" below and in
Agent 9's task.

---

## What exists today (recon-verified)

- **The MCP server is a stdio subprocess with a transport-agnostic core.**
  `MCPServer` is an actor whose entire public surface is `run(readingFrom:)` and
  `handle(_ frame: [UInt8]) async` (`Packages/OpenSheetsCore/Sources/SheetMCP/Server/MCPServer.swift:84,101`).
  `handle` never touches a file descriptor — every protocol test drives it directly
  (`Tests/SheetMCPTests/ProtocolTests.swift:52,87,101`). Framing is newline-delimited JSON-RPC
  with a 32 MB cap (`SheetMCP/JSONRPC/StdioTransport.swift:153-195`). The server serializes all
  dispatch (rationale at `MCPServer.swift:79-83`) and advertises tools only, protocol versions
  2025-06-18 / 2025-03-26 / 2024-11-05, echoing the client's version when supported
  (`MCPServer.swift:21-23,149-166`).
- **`opensheets-mcp` is a 3-line shim** over `OpenSheetsCLI.run(arguments: ["serve"])`
  (`CLI/opensheets-mcp/main.swift:19`); `serve` builds `SheetStore(mode: .mcpServer)`,
  `DocumentBroker`, `MCPServer`, then blocks on stdin (`CLI/CommandLine.swift:636-664`).
  `Scripts/build.sh:57-78` embeds the built binary at
  `OpenSheets.app/Contents/MacOS/opensheets-mcp`; `ClaudeConnector.serverBinary` finds it via
  `Bundle.main.url(forAuxiliaryExecutable:)` (`Sources/DocumentCore/ClaudeConnector.swift:135-146`).
- **Grants are enforced in the serving process and cannot be widened there.**
  `SheetStore(mode: .mcpServer)` yields `WorkspaceGrants(mode: .enforcementOnly)` whose
  `grant`/`revoke` throw (`Sources/SheetStore/SheetStore.swift:71-75`,
  `Sources/SheetStore/WorkspaceGrants.swift:203-205`). Every tool path funnels through
  `DocumentBroker.resolve`, whose first statement is `store.grants.check(path)`
  (`SheetMCP/Documents/DocumentBroker.swift:136-141`). Deny-list overrides grants
  (`WorkspaceGrants.swift:15-88`). Neither CLI binary links AppKit, so neither can construct
  `UserGrantAuthorization` (`Package.swift:121-122`).
- **Every tool schema carries `isReadOnly`/`isDestructive`** and emits MCP annotations
  (`SheetMCP/Tools/ToolSchema.swift:122-147`). `ToolRegistry.standard` lists the 25 tools
  (`SheetMCP/Tools/ToolRegistry.swift:123-149`); `MCPServer.init` takes any registry
  (`MCPServer.swift:66-76`).
- **The app is not sandboxed** (`Config/OpenSheets.entitlements`: `app-sandbox` false), so
  outbound `wss://` needs no entitlement today; default ATS allows `wss`/`https`
  (`Config/Info.plist` has no ATS key). The entitlements file carries a written tripwire:
  "Nothing here grants network access … a design smell worth arguing about"
  (`Config/OpenSheets.entitlements:23-25`).
- **There is zero networking code in the repo** — 379 Swift files, no `URLSession`, no
  `Network.framework`, no sockets. The reusable long-lived-service pattern is `FileWatcher`
  (`Sources/SheetStore/FileWatcher.swift:56-129`): injectable `Configuration` timings,
  generation counter, `AsyncStream` events, `start()`/`stop()`.
- **Persistence**: one GRDB 7 SQLite DB in WAL mode shared by app and server processes
  (`Sources/SheetStore/Database.swift:6-18`), append-only `DatabaseMigrator` currently at
  `v1-tables` + `v2-recent-file-sequence` (`Database.swift:75-137`). Storage protocols
  (`WorkspaceGrantStoring` at `WorkspaceGrants.swift:338`, `SnapshotIndexing` at
  `SnapshotStore.swift:401`) with `Database` conformances (`Database.swift:321,360`).
  Key/value JSON state goes in the `preference` table via `Persisted…` structs in
  `Sources/SheetStore/WorkspacePersistence.swift:5-32` (fail-soft reads, fail-silent writes,
  pinned `.sortedKeys, .withoutEscapingSlashes` encoder).
- **App wiring**: `AppModel` (`@MainActor @Observable`,
  `Sources/DocumentCore/AppModel.swift:48`) owns app-lifetime services; the precedent is
  `@ObservationIgnored public let claude: ClaudeConnector` (`AppModel.swift:76`), constructed
  in `init` (`:168`). Flags are `UserDefaults` booleans in `enum Flags`
  (`AppModel.swift:581-624`) re-exported by `App/Flags.swift:14`; the kill-switch bar is
  `OSFlagHandshake` — "off costs nothing, and that is structural rather than asserted"
  (`AppModel.swift:600-613`), with a per-instance `Bool?` test override (`:152`).
  Views must read grant state through `AppModel.isGranted(_:)` (`:377-386`), and anything
  acting on outside input reads `store.grants` live, never the cached array (`:447-449`).
- **Settings UI**: one `Form` in `PreferencesView` (`App/LauncherScene.swift:181-341`);
  the Claude section ends at `:220`. Row component precedent: `ClaudeClientRow`
  (`Sources/GlassUI/Chrome/ClaudeClientRow.swift`) — value in, actions out, GlassUI-local
  `Status: CaseIterable` with `label`, no glass surface of its own, appearance from
  `@Environment(\.glassAppearance)`. Captions/verbs are policy and live in the App layer
  (`LauncherScene.swift:258-261`); status words are identity and live in GlassUI
  (`ClaudeClientRow.swift:36-38`). Failures surface inline via
  `@State rejections` (`LauncherScene.swift:190-193`), never as alerts. The revocable-list
  row precedent is `SnapshotBrowser.row(_:)`
  (`Sources/GlassUI/Floating/SnapshotBrowser.swift:171-242`); the copy-to-clipboard idiom is
  the sidebar's `doc.on.clipboard` bordered small button + App-layer
  `NSPasteboard.general.clearContents()/setString` (`App/SidebarColumn.swift:207-212`,
  `Sources/GlassUI/Chrome/Sidebar.swift:563-581`).
- **No CLAUDE.md exists.** Conventions come from `DOCUMENTATION.md` §13, `PLAN.md` §13.1, and
  the plan template `.claude/plans/connect-to-claude-one-click.md`. Tests are swift-testing
  only. Lint-as-tests: `Tests/GlassUITests/GlassLintTests.swift` scans GlassUI **and `App/`**
  (no numeric `.padding`/`spacing:` literals except 0, colour literals only in `Tokens/`,
  no `@StateObject`/`.shared.`). There is no CI; `Scripts/build.sh` + `Scripts/test.sh` are
  the gate. One external dependency (GRDB, `Package.swift:65-69`).
- **Client requirements (researched 2026-08-30, sources in "Integrations")**:
  claude.ai custom connectors accept Streamable HTTP at a non-`/sse` URL with auth "None"
  (explicitly supported); ChatGPT developer mode (Pro/Plus/Business/Enterprise/Edu, web)
  accepts arbitrary MCP URLs with "No Authentication" and allows write tools with per-action
  confirmation; Gemini Enterprise accepts Streamable-HTTP-only servers with auth "None";
  Gemini's consumer surface (Spark custom apps; Google AI Pro/Ultra, US, personal accounts)
  exists but its no-auth support is **unverified**. Anthropic discourages credentials in
  URLs; the MCP spec prohibits tokens in the **query string** (path is not literally
  prohibited). Claude budgets: OAuth endpoints 10 s, tool calls 300 s, results ~150k chars.
  Don't build on `Mcp-Session-Id` (removed in MCP 2026-07-28); 2025-era clients still send
  `initialize`.

## Existing patterns to reuse

| Pattern | Where | Used by |
| --- | --- | --- |
| Transport seam: feed frames to `MCPServer.handle` / read newline frames | `SheetMCP/Server/MCPServer.swift:101`, `SheetMCP/JSONRPC/StdioTransport.swift:169` | Agent 6 (bridge pumps the subprocess's pipes) |
| Registry injection | `MCPServer.swift:66`, `ToolRegistry.swift:97-150` | Agent 4 (`--read-only` registry) |
| Subprocess conversation with the real binary, staged `HOME`+`CFFIXED_USER_HOME` | `Tests/SheetMCPTests/ShippedBinaryTests.swift:67-134,138-151` | Agents 6, 10 |
| Storage protocol + `Database` conformance + append-only migration | `WorkspaceGrants.swift:338`, `Database.swift:75-137,321` | Agent 1 |
| `preference`-table persisted struct, three-shape decoder idiom | `WorkspacePersistence.swift:55-142` | Agent 2 (device record) |
| Reconnecting service: injectable `Configuration`, generation counter, `AsyncStream` | `FileWatcher.swift:56-129,251-270` | Agent 6 (`RelayClient`) |
| App-lifetime service on `AppModel`, status via static pure mapping | `AppModel.swift:76,168,534-545` | Agent 7 |
| Kill-switch flag bar + per-instance override | `AppModel.swift:581-624,120-152` | Agent 7 |
| Settings row (value in/actions out, Status mirror, captions in App layer) | `ClaudeClientRow.swift`, `LauncherScene.swift:249-340` | Agents 5, 8 |
| Revocable list row with inline actions + destructive context menu | `SnapshotBrowser.swift:171-242` | Agent 5 |
| Copy-to-clipboard affordance | `SidebarColumn.swift:207-212`, `Sidebar.swift:563-581` | Agent 8 |
| Careful foreign-file write (not needed here, but the honesty voice) | `ClaudeConnector.swift:93-105` | Agent 9 (docs voice) |
| ULID | `SheetStore/ULID.swift:10` | Agents 1, 2 (link ids) |

## The policy line this feature must draw

`DOCUMENTATION.md` §5.9 argues a hosted bridge replaces "a process on your machine that a
human granted folders to" with "an endpoint on the internet holding a credential that grants
folders on your machine." The design answers that argument head-on, and the docs must say so:

1. **The relay holds no credential that grants anything.** It stores only SHA-256 hashes of
   link tokens and a device-secret hash, and routes frames. Grant enforcement, the deny-list,
   preview semantics, snapshots-before-writes, and the untrusted-content envelope all run in
   the same place they always ran: a local `opensheets-mcp` subprocess in
   `.enforcementOnly` mode on the owner's Mac. The relay cannot mint, widen, or bypass a
   grant; a fully compromised relay can do exactly what a person holding a valid link can do,
   and nothing more, and only while the app is running with Cloud Share enabled.
2. **Revocation is enforced twice.** The relay rejects revoked token hashes (fast path), and
   the app refuses to bridge frames for links its local database says are revoked
   (authoritative path, read live per request — the `AppModel.swift:447-449` rule). A stale
   or malicious relay cannot resurrect a revoked link.
3. **The `SheetMCP` target still makes no network requests** (`DOCUMENTATION.md:1893` stays
   literally true). All networking lives in the new app-side `SheetShare` target and the
   `Relay/` worker. `opensheets-mcp` remains a local stdio program; what changed is that the
   *app* may now pump its stdio to a socket — with the owner's explicit, revocable, per-link
   consent, off by default.
4. **Off costs nothing, structurally** (the `OSFlagHandshake` bar, `AppModel.swift:600-613`):
   with the flag off or the toggle off, no service object exists, no socket is opened, no
   Keychain item is read, no subprocess is spawned.
5. **What we cannot promise, we say**: the relay terminates TLS, so spreadsheet content
   transits the relay in plaintext per hop (client→relay, relay→Mac are both TLS; there is no
   end-to-end encryption to a third-party AI client). The relay is written to log no payloads.
   Anyone holding an active link can read (and, for read-write links, edit) every workbook in
   every granted folder. The docs state all three sentences plainly.

**Deny-list addition (narrowing only):** `~/Library/Application Support/OpenSheets` joins
`DenyList.standard` directories so a granted agent can never read the share-link store,
snapshots, or the DB through the tools. The three pinned deny-list tests
(`WorkspaceGrantsTests.swift:116`, `GrantEscapeTests.swift:122`, `ShippedBinaryTests.swift:288`)
are **not edited**; new assertions land in new test functions/files.

## Conventions every agent must follow (no CLAUDE.md exists; from DOCUMENTATION.md §13, PLAN.md §13.1)

1. Every new source file goes in a SwiftPM target under `Packages/OpenSheetsCore/Sources/`.
   **Never touch `OpenSheets.xcodeproj/project.pbxproj`.** No new files under `App/`.
2. `SheetModel` is frozen. Reuse existing `SheetError` cases; a genuinely new case goes to
   `docs/agents/MODEL-CHANGE-REQUESTS.md` in its documented format, with a workaround in place.
3. Preserve the DAG: new targets depend downward only; `DocumentCore` stays the sole
   all-importer; nothing depends on `DocumentCore`.
4. GRDB stays the only SwiftPM dependency. `URLSessionWebSocketTask` (Foundation),
   `Security.framework` (Keychain) and `CryptoKit` (hashing/random) are system frameworks,
   not dependencies.
5. Swift 6 language mode + `ExistentialAny`; zero warnings
   (`swift build -Xswiftc -warnings-as-errors`); no `TODO` placeholders; typed
   `SheetError`s with codes — never `fatalError`, `NSError`, or force-unwrap
   (`.swiftlint.yml:78-98`).
6. swift-testing only (`import Testing`, `@Test`); suites named as sentences, tests named as
   the claim they make; `.serialized` where parallelism would race; per-instance seams, not
   `UserDefaults`, for test overrides (`AppModel.swift:120-152`).
7. Grants: every path that reaches file APIs goes through the existing check funnels; the
   deny-list is only ever narrowed; the three pinned deny tests keep passing untouched.
8. Unfinished work ships dark behind a `UserDefaults` flag registered in `Flags.summary`
   (`App/Flags.swift:19-30`).
9. GlassUI lint applies to GlassUI **and** `App/`: no numeric literal in `.padding`/`spacing:`
   (0 excepted — use `DS.Space`/`DS.Metrics`), colour literals only in `Tokens/`, no
   `@StateObject`/`@EnvironmentObject`/`.shared.`, springs only, `.hoverTitle` not `.help`.
10. User-facing strings are hardcoded English literals. Captions and button verbs live in the
    App layer; status words live in GlassUI enums with `label`. Failures inline, never alerts;
    copy says what to do next.
11. Anything screen-unverified is recorded in `DOCUMENTATION.md` §12, not rounded up.
12. Branches: umbrella `feature/cloud-share`; per-agent `agent/a<n>-<slug>`; commit subjects
    `A<n>: <what>` with a why-carrying body; merge commits `Merge A<n>: <what>`. Trailer:
    `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
13. Scratch dirs in tests via `NSTemporaryDirectory()`, never `/tmp`
    (`Tests/SheetMCPTests/Support.swift:11-14`).

---

## Locked design

### Decisions

- **D1 — Serving stays local; the app bridges.** The app spawns the embedded
  `opensheets-mcp` binary (one subprocess per active link, lazily, idle-reaped) and pumps
  newline-framed JSON-RPC between the subprocess's stdio and the relay WebSocket. No second
  transport is added to `SheetMCP`; `MCPServer` and its stdio loop are untouched. This
  preserves every property §5.9 defends: `.enforcementOnly` grants, no-AppKit barrier,
  deny-list, per-process isolation, and the existing two-process WAL DB topology.
- **D2 — The relay is a Cloudflare Worker + one Durable Object per device.** The Mac holds an
  outbound WebSocket to its DO (hibernation-friendly); MCP HTTP requests to a link URL are
  routed to the same DO and forwarded over that socket. DO storage holds only
  `{deviceSecretHash, tokenHashHex → {linkId, revoked}}`. No payload logging, no content
  storage. New top-level `Relay/` directory, TypeScript + wrangler + vitest — the repo's
  second toolchain, isolated to that directory (OPEN-2).
- **D3 — v1 auth is an authless capability URL.** Token in the URL **path** (never the query
  string), 256 bits of entropy, revocable, shown with copy affordance. Recipients paste the
  URL and pick auth "None" (Claude) / "No Authentication" (ChatGPT dev mode). This is the
  only mode that satisfies "zero recipient setup" today. OAuth 2.1 (CIMD + RFC 9728, one-click
  consent page, no accounts) is the designed upgrade path, deliberately out of scope for v1
  (OPEN-3).
- **D4 — Links have a mode: `read_only` (default) or `read_write`.** Enforced on the Mac by
  spawning the subprocess with a filtered registry (`serve --read-only` → only tools whose
  `ToolSchema.isReadOnly` is true), so a read-only link's `tools/list` doesn't even advertise
  write tools. The relay does not know or enforce modes.
- **D5 — Token format** (locked, both sides implement from this spec):
  `os1.<deviceId>.<secret>` where `deviceId` = 22-char base64url of 16 random bytes and
  `secret` = 43-char base64url of 32 random bytes. Link URL:
  `https://<relay-host>/mcp/os1.<deviceId>.<secret>`. The relay routes on the `deviceId`
  segment and authenticates by comparing SHA-256(full token) against stored hashes. The
  plaintext token exists only on the owner's Mac (DB `url` column) and in whatever the owner
  pastes; the relay stores hashes only.
- **D6 — Device identity**: `deviceId` (not secret) in the `preference` table as a
  `PersistedCloudDevice` JSON row (key `cloud.device`); the device **secret** (32 random
  bytes, distinct from link tokens) lives in the macOS Keychain
  (`kSecClassGenericPassword`, service `com.quino.opensheets.cloud-share`, account `device`).
  First WebSocket `hello` registers the secret hash in the DO (trust-on-first-use; the DO id
  is 128-bit random, unguessable before registration).
- **D7 — Share-link records** live in a new `share_link` table (migration `v3-share-links`)
  in the shared DB, written only by the app. The full URL is stored plaintext so Copy works
  anytime; in exchange, `~/Library/Application Support/OpenSheets` joins the deny-list (see
  policy line). Revoked links stay listed until removed.
- **D8 — Request bridging is serialized per link.** For an inbound frame with an `id`, the
  bridge writes the frame and awaits the next stdout line as its response (the server emits
  no unsolicited lines: no notifications, `listChanged: false`, logging off —
  `MCPServer.swift:149-166`); notifications (no `id`) are written without awaiting and the
  relay answers HTTP 202. Concurrency ceiling of 1 in-flight call per link matches the
  server's own serialization (`MCPServer.swift:79-83`).
- **D9 — Sessions are decorative.** The relay mints a random `Mcp-Session-Id` on `initialize`
  responses (2025-era clients expect one) but routes purely by token; it ignores the header on
  subsequent requests, answers `DELETE` with 200 and `GET` with 405. Nothing is built on
  session state (MCP 2026-07-28 removes it). One subprocess per link serves all sessions of
  that link; repeated `initialize` frames are harmless (`MCPServer.swift:122-166`).
- **D10 — Flag + toggle.** `OSFlagCloudShare` defaults **off** (ships dark; the relay isn't
  deployed and the pane is screen-unverified — the `OSFlagSheetStructure` precedent,
  `AppModel.swift:619`). A separate user-facing master toggle `OSCloudShareEnabled`
  (UserDefaults, default false) starts/stops the service when the flag is on. Off ⇒ no
  service object, no socket, no Keychain read, no subprocess — asserted by a test, the
  `OSFlagHandshake` bar.
- **D11 — Entitlements**: add `com.apple.security.network.client = true` (inert while
  unsandboxed; preserves the "future sandboxed build is a build-setting change" promise at
  `Config/OpenSheets.entitlements:15-17`) and rewrite the tripwire comment to name Cloud
  Share as the argued-for exception, in the file's own voice.
- **D12 — Relay endpoint is Streamable HTTP only**, at `/mcp/<token>` (no `/sse` suffix, no
  legacy SSE endpoint). POST with `Accept: application/json[, text/event-stream]` →
  `application/json` single-response mode. Offline Mac → immediate JSON-RPC error, never a
  hang (Claude's 300 s tool budget; our relay timeout is 120 s).

### User flow (owner)

1. Settings (⌘,) → **Cloud** section (below Claude). Empty state caption:
   "Share links let ChatGPT, Claude, or Gemini work with your granted folders through
   OpenSheets. New Link creates one and copies it." Master toggle **Cloud Share** (off).
2. Owner flips **Cloud Share** on. Status row shows `Connecting…` → `Online` (green
   `AgentDot`), or `Offline — retrying` with the reason as detail. First enable generates the
   device identity and connects.
3. Owner types a name in the inline create row ("Who is this for? e.g. Ana"), leaves mode
   picker at **Read only** (or picks **Read & write**), clicks **Create & Copy**. A row
   appears — name, mode word, `os1.…` URL middle-truncated in `DS.Text.path`, "Created just
   now" — and the full URL is on the clipboard. Caption under the create row:
   "Anyone with this link can read your granted folders. Read & write links can also edit."
4. Owner pastes the link to a person; the recipient adds it in their assistant
   (claude.ai → Settings → Connectors → Add custom connector → paste URL, auth None;
   ChatGPT → enable Developer mode → Add MCP server → paste URL, No Authentication) and
   prompts away. `describe`, `read_range` etc. flow; on a read-write link, edits land on disk
   and the owner's open window shows the normal changed-on-disk pill.
5. The row's "Last used" updates as calls arrive (relative, e.g. "2 min ago").
6. Revoke: row's context menu (or inline button when selected) → **Revoke** (destructive
   role). Row greys to status word `Revoked`; the relay rejects the hash on its next request;
   the app refuses to bridge it regardless. **Remove from list** (context menu, only on
   revoked rows) deletes the record.
7. Toggle off: socket closes, subprocesses die, rows stay listed, links answer "offline" to
   callers until re-enabled.
8. Error states, all inline in the section (rejection idiom, never an alert):
   relay unreachable → status `Offline — retrying`, detail "Check your internet connection.
   Links keep working when OpenSheets reconnects."; link creation failure → rejection line
   under the create row; revoked-but-unsynced (Mac offline at revoke time) → status detail
   "Revocations sync when back online." (the app refuses bridging immediately either way).

Recipient flow (documented, no code): paste URL → auth None → prompt. If the owner's Mac is
offline/closed, tools fail with: "OpenSheets is offline on the owner's Mac. Ask them to open
OpenSheets and check Settings → Cloud."

### Wire contract A — app ⇄ relay WebSocket (implemented from this spec by Agents 2, 3, 6)

Connect: `wss://<relay-host>/agent` with headers `Authorization: Bearer <deviceSecret>` and
`X-OpenSheets-Device: <deviceId>`. All messages are single-line JSON objects with a `type`
field, encoded with sorted keys. Unknown fields are ignored; unknown `type`s are ignored
(forward compatibility). `v` is the protocol version, currently `1`.

App → relay:
```json
{"type":"hello","v":1,"deviceId":"<22 chars>","appVersion":"0.1.0",
 "links":[{"linkId":"<ULID>","tokenHash":"<64 hex>","revoked":false}]}
{"type":"link_upsert","link":{"linkId":"…","tokenHash":"…","revoked":true}}
{"type":"response","requestId":"<relay-minted>","status":"ok","body":"<JSON-RPC frame as string>"}
{"type":"response","requestId":"…","status":"error","error":"subprocess_failed"}
```
Relay → app:
```json
{"type":"hello_ack","v":1}
{"type":"ack","op":"link_upsert","linkId":"…"}
{"type":"request","requestId":"<random>","linkId":"<ULID>","expectsReply":true,"body":"<JSON-RPC frame as string>"}
{"type":"error","code":"auth_failed"}   // then close 4401
```
Rules: `hello` is mandatory first message; the relay replaces its stored link set with the
`hello` list (reconciliation heals backup-restore drift) and must process it before routing
any request. `expectsReply` is false for JSON-RPC notifications (no `id`) — the app writes
the frame to the subprocess and sends no `response`. TOFU: first `hello` for an unknown
`deviceId` stores SHA-256(deviceSecret); later connects must match or the socket closes 4401.
Mode (`read_only`/`read_write`) is **not** sent to the relay — the Mac enforces it. WebSocket
ping/pong at 30 s keeps hibernation cheap. Frame bodies ≤ 8 MB (relay caps request bodies at
4 MB; responses pass through up to 32 MB, mirroring `FrameReader.maximumFrameBytes`).

### Wire contract B — client ⇄ relay HTTP (implemented by Agent 3)

- `POST /mcp/os1.<deviceId>.<secret>` — body: one JSON-RPC message. Relay: parse token from
  path → DO(deviceId) → hash-compare → if unknown/revoked, **404 with empty body** (do not
  reveal which); if device socket absent or `response` doesn't arrive in 120 s and the request
  had an `id`, answer 200 `application/json` with
  `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32000,"message":"OpenSheets is offline on the owner's Mac. Ask them to open OpenSheets and check Settings → Cloud."}}`;
  otherwise forward and return the subprocess's response as `application/json`.
  Notifications (no `id`): forward with `expectsReply:false`, answer `202` immediately.
  On a successful `initialize` response, set header `Mcp-Session-Id: <random>` (D9).
- `GET /mcp/<token>` → 405. `DELETE /mcp/<token>` → 200 empty (client session cleanup).
- `GET /health` → 200 `{"ok":true}`.
- `MCP-Protocol-Version` request header: accepted and ignored (the subprocess negotiates in
  the `initialize` body; it echoes 2025-06-18/2025-03-26/2024-11-05 and counter-offers
  2025-06-18 otherwise, which 2025-era clients accept).
- CORS: none needed (server-to-server callers), but answer `OPTIONS` 204 harmlessly.

### Database (Agent 1)

Migration `v3-share-links` appended in `Database.migrator` (`Database.swift:75`):

```sql
CREATE TABLE share_link (
  id            TEXT PRIMARY KEY,            -- ULID
  name          TEXT NOT NULL,               -- owner-facing label, e.g. "Ana"
  url           TEXT NOT NULL,               -- full capability URL, plaintext (D7)
  token_hash    TEXT NOT NULL UNIQUE,        -- SHA-256 hex of "os1.<deviceId>.<secret>"
  mode          TEXT NOT NULL DEFAULT 'read_only',  -- 'read_only' | 'read_write'
  created_at    DATETIME NOT NULL,
  revoked_at    DATETIME,                    -- NULL = active
  last_used_at  DATETIME
);
CREATE INDEX index_share_link_on_created_at ON share_link(created_at);
```

Rollback: drop the table (no other object references it; migrations are append-only so the
practical rollback is a no-op — the table sits unused when the flag is off). No backfill.
Device identity: `preference` row `cloud.device` → `PersistedCloudDevice {deviceId, createdAt}`
(house Persisted… idiom, `WorkspacePersistence.swift:55-142`); secret in Keychain (D6).

### Backend (relay, Agent 3)

`Relay/` — `wrangler.toml` (DO binding `SHARE_HUB` → class `ShareHub`, SQLite-backed DO),
`src/index.ts` (router: `/agent` upgrade, `/mcp/*`, `/health`), `src/shareHub.ts` (DO:
socket lifecycle, TOFU auth, link table, request/response correlation with 120 s timeout),
`src/token.ts` (parse/validate/hash), `test/*.spec.ts` (vitest +
`@cloudflare/vitest-pool-workers`), `package.json`, `tsconfig.json`, `README.md` (deploy:
`npm ci && npx wrangler deploy`; the deploy itself is a user step — OPEN-1). No analytics, no
payload logging; `console.log` only for connection lifecycle with ids, never bodies.

### Frontend

- **GlassUI (Agent 5)** — new `Sources/GlassUI/Chrome/CloudShareRows.swift`:
  - `CloudShareStatus: String, CaseIterable, Sendable` — `disabled`, `connecting`, `online`,
    `offline`, `revokedPending` is NOT a status (it's per-link); each case has `label`
    (`Off` / `Connecting…` / `Online` / `Offline — retrying`) and
    `signal: DS.SignalKind` (`.neutral/.neutral/.agent/.conflict`). Identity words only —
    detail sentences are App-layer captions.
  - `ShareLinkRowModel: Sendable, Equatable, Identifiable` — `id: String`, `name`,
    `modeWord` (`"Read only"`/`"Read & write"` — identity), `urlDisplay`, `createdDetail`,
    `lastUsedDetail`, `isRevoked: Bool`, `rejection: String?`.
  - `ShareLinkRowAction` — `.copy`, `.revoke`, `.remove`.
  - `ShareLinkRow: View` — structural clone of `SnapshotBrowser.row`
    (`SnapshotBrowser.swift:171-242`) sized for a Settings `Form`: name
    (`DS.Text.controlEmphasis`) + mode word + status word when revoked; URL line in
    `DS.Text.path`, `.truncationMode(.middle)`, `.textSelection(.enabled)`,
    `.hoverTitle(url)`; trailing copy icon button (sidebar idiom) and context menu with
    `Button("Revoke", role: .destructive)` / `Button("Remove from list", role: .destructive)`
    (remove only when revoked). Draws no glass surface ⇒ no gallery/catalog/golden entries
    (the `ClaudeClientRow`/`FileExplorer.swift:5-15` precedent). Appearance via
    `@Environment(\.glassAppearance)`. `spokenSummary` for VoiceOver like
    `ClaudeClientRow.swift:166-172`.
- **App layer (Agent 8)** — `Section("Cloud")` inserted at `App/LauncherScene.swift:220`:
  master `Toggle("Cloud Share", …)` bound to `OSCloudShareEnabled` via `@AppStorage`; status
  row (`AgentDot` + `CloudShareStatus.label` + App-written caption); inline create row
  (`TextField("Who is this for?", text:)`, `Picker` read-only/read-write,
  `Button("Create & Copy")`); `ForEach` of `ShareLinkRow`; empty-state caption
  (inline, `DS.Text.caption`/`DS.Chrome.tertiary` — the `Sidebar.swift:381-384` idiom);
  `@State rejections: [String: String]` keyed by link id + one `createRejection: String?`.
  All captions/verbs written here. Clipboard writes here
  (`NSPasteboard.general.clearContents()` + `setString`). The whole section renders only when
  `Flags.cloudShareEnabled` is true (flag off ⇒ section absent — "absent means absent").

### App-side service (Agents 2, 6, 7)

New SwiftPM leaf target **`SheetShare`** (depends on `SheetModel`, `SheetStore` only;
`DocumentCore` gains a `SheetShare` dependency; added to the umbrella product):

- `RelayProtocol.swift` (Agent 2) — `Codable` message types for wire contract A, with a
  pinned sorted-keys encoder (`WorkspacePersistence.swift:129` idiom) and decode-ignoring
  unknown types.
- `ShareToken.swift` (Agent 2) — mint (CryptoKit `SecureBytes`-equivalent via
  `SystemRandomNumberGenerator`/`SecRandomCopyBytes`), format/parse `os1.` tokens, SHA-256
  hex. Pure; fully unit-tested.
- `DeviceIdentity.swift` (Agent 2) — `DeviceIdentityStoring` protocol
  (`loadOrCreate() throws(SheetError) -> DeviceIdentity`), `KeychainDeviceIdentityStore`
  (SecItem generic password; every failure maps to an existing `SheetError` case with the
  OSStatus in the message) + `InMemoryDeviceIdentityStore` for tests.
- `RelayClient.swift` (Agent 6) — actor over an injectable
  `RelaySocket` protocol (production: `URLSessionWebSocketTask`); `FileWatcher`-style
  `Configuration` (reconnect floor 1 s, cap 60 s, jitter, ping 30 s), generation counter,
  `AsyncStream<RelayEvent>`, `start()`/`stop()`.
- `LinkBridge.swift` (Agent 6) — actor owning per-link subprocess lifecycle: spawn embedded
  binary (URL injected) with `["--read-only"]` for read-only links, pipes, newline framing
  (32 MB cap), serialized request→response per D8, idle reap (5 min, injectable), kill on
  revoke, respawn-on-crash with error `response` for the in-flight request.
- `CloudShareEngine.swift` (Agent 6) — composes RelayClient + LinkBridge + `ShareLinkStoring`
  + live revocation check per inbound request (re-read the record, the `store.grants`-live
  rule) + `last_used_at` writes.
- `CloudShareService.swift` (Agent 7, in `Sources/DocumentCore/`) — `@MainActor @Observable`
  facade owned by `AppModel` (`@ObservationIgnored public let share:`): `status`, `links`,
  `createLink(name:mode:) throws(SheetError) -> ShareLinkRecord`, `revoke(id:)`,
  `remove(id:)`, `setEnabled(Bool)`, `refresh()`; static
  `CloudShareService.status(for:) -> CloudShareStatus` pure mapping
  (the `AppModel.mcpStatus(for:)` idiom, `AppModel.swift:534-545`). Flag-gated construction:
  `Flags.cloudShareEnabled == false` ⇒ `AppModel.share` is `nil` and nothing is built
  (kill-switch bar), with `cloudShareForThisInstance: Bool?` per-instance override.

### Permissions (who can do what, enforced where)

| Action | Enforced at | Mechanism |
| --- | --- | --- |
| Read/edit a workbook via a link | Mac, subprocess | `WorkspaceGrants` `.enforcementOnly` + deny-list, unchanged funnels (`DocumentBroker.swift:136-141`) |
| Use write tools on a read-only link | Mac, subprocess | filtered registry — write tools absent from `tools/list` and dispatch (`--read-only`, D4) |
| Use a revoked link | Relay **and** Mac | hash rejected (404) at relay; app refuses to bridge after live DB re-read (D8/engine) |
| Create/revoke links | Mac, app only | only the app writes `share_link`; the relay accepts link state only from an authenticated device socket |
| Impersonate the device | Relay | TOFU secret hash; 4401 on mismatch; secret only in the owner's Keychain |
| Read the share store via the tools | Mac, subprocess | new deny-list entry for `~/Library/Application Support/OpenSheets` |
| Reach the pane at all | App | `OSFlagCloudShare` flag + `OSCloudShareEnabled` toggle, both default off |

Assume a hostile client: every inbound frame is bytes to a subprocess that already treats
paths, arguments, and cell content as untrusted (`UntrustedContent`, grant checks, preview).
The bridge adds no parsing of frame contents beyond JSON-RPC `id` extraction.

### Validation

| Field | Rule | Where | Failure message |
| --- | --- | --- | --- |
| Link name | trimmed non-empty, ≤ 64 chars | App (create row) + service | "Name the link so you can revoke the right one later." (button disabled until valid; message as caption) |
| Mode | `read_only` \| `read_write` | Swift enum + DB CHECK-by-convention (TEXT) | n/a (unrepresentable) |
| Token | exactly `os1.<22 b64url>.<43 b64url>` | relay `src/token.ts` + `ShareToken` parse | relay: 404; app: `SheetError` invalid-argument case |
| `hello` before requests | first message | relay DO | close 4401 |
| Frame size | request ≤ 4 MB at relay; ≤ 32 MB at bridge | relay + `LinkBridge` | JSON-RPC error `resultTooLarge` text idiom |
| Device secret | 32 bytes | `DeviceIdentity` | throws typed `SheetError` with OSStatus |

### Edge cases (intended behavior, each one tested where testable)

- **App quits / Mac sleeps**: socket drops; relay answers offline error; on wake, backoff
  reconnect + `hello` reconciliation; links resume with no user action.
- **Revoke while a call is in flight**: the in-flight call completes; the next frame for that
  link is refused by the app and its hash by the relay.
- **Revoke while offline**: app marks revoked locally (bridging refused immediately);
  `link_upsert` replays via the next `hello`; status detail says "Revocations sync when back
  online."
- **Two clients, one link, concurrently**: serialized per link (D8); second call waits; no id
  collision possible because responses are consumed in order.
- **Subprocess crash mid-call**: bridge sends `response(status:"error")`, relay converts to
  the offline-style JSON-RPC error with the original `id`; bridge respawns lazily.
- **DB restored from Time Machine**: `hello` replaces the relay's link set; links created
  after the backup die (hash unknown), links revoked after the backup are re-revoked.
- **Relay redeploy**: DO storage persists; sockets reconnect via backoff.
- **Duplicate `initialize`** (client retry / second session): harmless
  (`MCPServer.swift:122-166` resets negotiated version only).
- **Oversize workbook read** (~150k char client caps): the tools already paginate/truncate;
  no relay handling needed beyond the 32 MB pass-through.
- **Grant revoked in the app mid-session**: next tool call fails with the standard grant
  refusal — the subprocess's `WorkspaceGrants` reload/`invalidateCache` behavior is
  unchanged.
- **Link URL pasted into a client that requires `/sse`**: unsupported by design; docs say
  Streamable HTTP only.
- **Token in logs**: relay never logs URLs or bodies; the app logs link *ids* only.
- **`hello` with zero links**: valid; relay clears its table (all links dead until upserted).

### Tests

Commands (every agent runs the ones for its layer; Agent 11 runs all):

```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors
cd Packages/OpenSheetsCore && swift test  -Xswiftc -warnings-as-errors
cd Packages/OpenSheetsCore && swift test  -Xswiftc -warnings-as-errors --filter <Suite>
Scripts/build.sh --package-only
Scripts/build.sh   # then: test -x "<app>/Contents/MacOS/opensheets-mcp"
cd Relay && npm ci && npm test     # relay only
git diff --stat                    # docs agent: markdown only
```

Known-flaky, do not chase: `CoreLoopTests`, `CellStore performance`
(`DOCUMENTATION.md:2590-2608`).

| Layer | Suite (new) | Key assertions |
| --- | --- | --- |
| SheetStore | `ShareLinkStoreTests` | insert/list/revoke/remove/last-used round-trip; token_hash uniqueness; migration applies on a v2 DB |
| SheetStore | `DenyListShareStoreTests` (new file) | the OpenSheets app-support dir is denied through the tools funnel; the three pre-existing pinned deny tests are untouched and still pass |
| SheetShare | `ShareTokenTests` | format/parse/reject; hash is stable hex; 100 mints are unique |
| SheetShare | `RelayProtocolTests` | encode is byte-stable (sorted keys); decoder ignores unknown fields/types; every message round-trips |
| SheetShare | `DeviceIdentityTests` | in-memory store loadOrCreate is idempotent; Keychain store create→load→delete round-trip with a test-only service name |
| SheetShare | `RelayClientTests` | fake socket: connect→hello→ack; backoff schedule under injected timings; generation counter discards stale events; stop() closes |
| SheetShare | `LinkBridgeTests` | against the **real built binary** (ShippedBinaryTests pattern, staged `HOME`/`CFFIXED_USER_HOME`): initialize round-trips; read_only spawn's tools/list contains no write tool; notification frames produce no response; idle reap kills; revoke kills; crash → error response |
| SheetMCP | `ReadOnlyServeTests` | `ToolRegistry.readOnly` == exactly the `isReadOnly` schemas (write_range absent, read_range present); `serve --read-only` parses; shim passes args through |
| DocumentCore | `CloudShareServiceTests` | flag off ⇒ no service, no store touch (kill-switch bar); status mapping table total; createLink writes DB + returns URL; revoke flips record |
| GlassUI | `ComponentModelTests` additions | every `CloudShareStatus` names itself, no two share a word; `ShareLinkRowModel` equality; action cases |
| E2E | `EndToEndShareTests` | fake relay transport → engine → real subprocess → real staged DB: paste-to-first-tool-call flow, revoke-mid-session, offline error shape |
| Relay | vitest specs | token parse/reject; TOFU auth; unknown/revoked hash → 404; offline → -32000 body with id echo; hello reconciliation; notification → 202; timeout → error |

### Rollout

1. **Wave order is merge order** (below). Everything app-side ships dark: `OSFlagCloudShare`
   defaults off; the section doesn't render; no code path constructs the service.
2. **User step (not an agent step)**: create/choose a Cloudflare account, `cd Relay &&
   npx wrangler deploy`, note the `workers.dev` URL (OPEN-1). Until then the compiled default
   relay host is a placeholder and the flag stays off.
3. Bake the real relay URL as the `CloudShareConfiguration.standard` default (one-line
   follow-up), verify on screen (create → paste into claude.ai → tool call → revoke), record
   anything unverified in `DOCUMENTATION.md` §12.
4. Flip `OSFlagCloudShare` default to on in a later release, per the "flag exists to ship
   dark code" rule (`PLAN.md:506-513`).
5. Roll back: flip the flag off (structural off), or `wrangler delete` the worker (all links
   die with a clean offline error).

### Integrations

- **Cloudflare Workers + Durable Objects** — the only third-party service. Account and
  deploy are user steps; no secrets in the repo (wrangler uses its own login). Env names
  (relay): none required for v1. App: UserDefaults `OSCloudRelayURL` overrides the compiled
  relay origin for development.
- **System frameworks newly used**: Foundation `URLSessionWebSocketTask` (SheetShare),
  `Security` (Keychain, SheetShare), `CryptoKit` (already used for SHA-256).
- **Client docs** (for `docs/cloud-share.md`): claude.ai custom connectors
  (support.claude.com/en/articles/11175166, claude.com/docs/connectors/custom/remote-mcp),
  ChatGPT developer mode (developers.openai.com/api/docs/guides/developer-mode), Gemini
  Spark custom apps (support.google.com/gemini/answer/17209137), Gemini Enterprise custom
  MCP (docs.cloud.google.com/gemini/enterprise/docs/connectors/custom-mcp-server), MCP
  Streamable HTTP + Authorization specs (modelcontextprotocol.io).

---

## OPEN decisions (proceeding on the recommendation)

- **OPEN-1 — Relay host.** Recommendation: **Cloudflare Workers + Durable Objects** (WebSocket
  hibernation, per-device isolation, generous free tier, single-file deploy). Alternatives
  considered: Supabase Edge Functions (no durable socket — wall-clock limits make a
  persistent agent connection fragile; the existing Supabase org's projects are unrelated),
  Fly.io (a real server to operate). Requires the owner's Cloudflare account and a
  `wrangler deploy`; v1 uses the `*.workers.dev` origin, custom domain later.
- **OPEN-2 — A second toolchain in the repo.** `Relay/` is TypeScript + wrangler + vitest,
  isolated to one directory, never imported by the Swift package, and versioned with the app
  because the wire contract is one artifact. Alternative (separate repo) rejected for v1:
  the contract would drift. This does not touch the "one SwiftPM dependency" rule.
- **OPEN-3 — v1 auth = authless capability URL** (D3). Anthropic's docs discourage
  credentials in URLs and the org-managed Claude admin flow may not offer "None"; Gemini
  Spark's no-auth support is unverified. Mitigations: 256-bit token in the path (never query),
  revocation + last-used visibility, default read-only, off by default, relay stores hashes
  only. The upgrade path (relay-hosted OAuth 2.1 with a one-click consent page bound to the
  link, CIMD + RFC 9728) is designed but deliberately deferred.
- **OPEN-4 — Default link mode = read only** (D4). "Prompt and get access" is served by
  reads; handing `delete_file`/`write_range` to a shared link should be a deliberate click.
- **OPEN-5 — Naming.** Target `SheetShare`, flag `OSFlagCloudShare`, toggle
  `OSCloudShareEnabled`, section title "Cloud". Cheap to change before Wave 1 merges.

## Deliberately out of scope (v1)

- OAuth for recipients (OPEN-3), per-link folder scoping narrower than the workspace grants,
  a sidebar Cloud panel (Settings only — avoids `Sidebar.swift`/gallery churn), link
  expiry dates, rename-after-create, QR codes, Gemini Spark verification (recorded as a §12
  gate), SSE legacy endpoint, relay-side analytics of any kind, and multi-device link
  migration.

---

## Agent tasks

### Agent 1 — share_link storage and the store-directory deny rule
**Goal:** `share_link` exists as a migrated table behind a `ShareLinkStoring` protocol, and
the OpenSheets app-support directory is deny-listed to the tools.
**Depends on:** none — can start immediately.
**Files to create:**
`Packages/OpenSheetsCore/Sources/SheetStore/ShareLinks.swift`,
`Packages/OpenSheetsCore/Tests/SheetStoreTests/ShareLinkStoreTests.swift`,
`Packages/OpenSheetsCore/Tests/SheetStoreTests/DenyListShareStoreTests.swift`.
**Files to modify:**
`Packages/OpenSheetsCore/Sources/SheetStore/Database.swift` — append migration
`v3-share-links` in `migrator` (`:75-137`) and add a `ShareLinkStoring` conformance extension
beside the existing ones (`:321,360`);
`Packages/OpenSheetsCore/Sources/SheetStore/WorkspaceGrants.swift` — add the app-support
directory to `DenyList.standard` directories (`:31-42`) with a one-line comment saying why
(share tokens and snapshots live there).
**Do NOT touch:** the three pinned deny tests (`Tests/SheetStoreTests/WorkspaceGrantsTests.swift:116`,
`Tests/SheetMCPTests/GrantEscapeTests.swift:122`,
`Tests/SheetMCPTests/ShippedBinaryTests.swift:288`) — new assertions go in the new file;
`Package.swift` (Agent 2 owns it; SheetStore files need no manifest edit); anything in
`SheetMCP`/`DocumentCore`.
**Context it needs:** migration + conformance shape: `Database.swift:75-137` and
`WorkspaceGrantStoring` (`WorkspaceGrants.swift:338`) / `SnapshotIndexing`
(`SnapshotStore.swift:401`) with conformances at `Database.swift:321-358,360+`; row-type
idiom with snake_case CodingKeys: `RecentFile` (`Database.swift:257-280`); ULID:
`SheetStore/ULID.swift:10`; error translation via the existing `run`/`write` helpers
(`Database.swift:234,245`); deny-list semantics and case-insensitivity
(`WorkspaceGrants.swift:11-14,31-88`). The deny path must be the *configured* app-support
dir, not a hardcoded `~` string — thread it the way `Configuration.standard()` resolves it
(`SheetStore.swift:26-36`); `DenyList.standard` takes the home/support URLs it expands today,
follow that construction.
**Implementation notes:** DDL exactly as in "Database" above. Public types:
`public struct ShareLinkRecord: Sendable, Equatable, Identifiable` (`id: ULID`, `name`,
`url`, `tokenHash`, `mode: ShareLinkMode`, `createdAt`, `revokedAt: Date?`,
`lastUsedAt: Date?`, `var isActive: Bool`), `public enum ShareLinkMode: String, Sendable,
CaseIterable` (`readOnly = "read_only"`, `readWrite = "read_write"`),
`public protocol ShareLinkStoring: Sendable` (`insert`, `all() -> [ShareLinkRecord]`,
`record(id:)`, `revoke(id:at:)`, `delete(id:)`, `touchLastUsed(id:at:)`,
`activeRecord(tokenHash:)`). Reuse `SheetError.databaseError` for failures. Add a
`SheetStore.shareLinks` accessor mirroring how `grants` is exposed (`SheetStore.swift:53`),
available in both modes (the engine reads it in-process; the subprocess never does).
**Acceptance criteria:**
1. `swift test --filter ShareLinkStoreTests` passes, ≥ 8 tests: round-trip, uniqueness
   violation surfaces as a typed error, revoke is soft, delete removes, `touchLastUsed`
   updates, `activeRecord(tokenHash:)` misses on revoked, migration applies over a DB that
   already ran v1+v2.
2. `DenyListShareStoreTests` proves a grant of `~/Library` still cannot read a file under
   the OpenSheets app-support dir through `WorkspaceGrants.check`.
3. The three pinned deny tests pass **without any edit** (`git diff` shows no change to those
   files).
4. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors` and full
   `swift test -Xswiftc -warnings-as-errors` pass.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'ShareLinkStoreTests|DenyListShareStoreTests'
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
git diff --name-only   # must not list the three pinned test files
```

### Agent 2 — SheetShare target: token, wire protocol, device identity
**Goal:** the `SheetShare` target exists with the pure primitives every later agent compiles
against: token mint/parse/hash, wire-contract-A message types, device identity storage.
**Depends on:** none — can start immediately.
**Files to create:**
`Packages/OpenSheetsCore/Sources/SheetShare/ShareToken.swift`,
`Packages/OpenSheetsCore/Sources/SheetShare/RelayProtocol.swift`,
`Packages/OpenSheetsCore/Sources/SheetShare/DeviceIdentity.swift`,
`Packages/OpenSheetsCore/Sources/SheetShare/CloudShareConfiguration.swift`,
`Packages/OpenSheetsCore/Tests/SheetShareTests/ShareTokenTests.swift`,
`Packages/OpenSheetsCore/Tests/SheetShareTests/RelayProtocolTests.swift`,
`Packages/OpenSheetsCore/Tests/SheetShareTests/DeviceIdentityTests.swift`.
**Files to modify:** `Packages/OpenSheetsCore/Package.swift` — add `SheetShare` target
(deps: `SheetModel`, `SheetStore`; `swiftSettings: strictSettings`), its `.library` product,
membership in the umbrella `OpenSheetsCore` product (`:50-63`), a
`.testTarget(name: "SheetShareTests", dependencies: ["SheetShare", "TestSupport"])`, and a
`DocumentCore → SheetShare` dependency edge **with a justifying comment** (the
`DocumentCore → SheetMCP` precedent carries one at `Package.swift:95-103`).
**Do NOT touch:** any existing Swift source file; `project.pbxproj`; `Relay/` (Agent 3);
`Sources/SheetStore/*` (Agent 1).
**Context it needs:** manifest shape and `strictSettings` (`Package.swift:26-29,34-63,73-129`);
DAG rule ("new leaf beside Wave-1 targets"); pinned-encoder idiom
(`WorkspacePersistence.swift:123-142`); `PersistedCloudDevice` goes here? **No** — the
`preference`-row struct convention says key strings + payload shapes live in the lowest
shared target (`WorkspacePersistence.swift:5-22`), but only the app reads this one, so keep
`PersistedCloudDevice` in `SheetShare` reading through a constructor-injected
`(String) -> String?` / `(String, String?) -> Void` pair rather than depending on `Database`
directly; wire contract A is normative above — implement it byte-for-byte; existing
`SheetError` cases only (`SheetModel/SheetError.swift`) — map Keychain OSStatus into an
existing IO/internal case's message, do not add cases.
**Implementation notes:** `ShareToken.mint(deviceId:)` uses `SecRandomCopyBytes`; base64url
without padding; `ShareToken.hash` = SHA-256 hex of the full `os1.…` string (CryptoKit).
`RelayMessage` is an enum with a custom `Codable` keyed on `type`, unknown types decode to
`.unknown` (never throw — forward compat). `CloudShareConfiguration` holds `relayOrigin: URL`
(placeholder default `https://opensheets-relay.example.workers.dev` with a comment naming the
OPEN-1 user step), `agentPath = "/agent"`, `mcpPath = "/mcp/"`, plus
`static func linkURL(origin:token:)`. Keychain store: service
`com.quino.opensheets.cloud-share`, account `device`; tests use a distinct service name
`com.quino.opensheets.cloud-share.tests` and delete in `defer`.
**Acceptance criteria:**
1. `swift test --filter 'ShareTokenTests|RelayProtocolTests|DeviceIdentityTests'` passes;
   token format matches D5 exactly (asserted with a regex); protocol encoding is
   byte-reproducible and matches the JSON shapes in wire contract A (pinned-bytes test).
2. `Scripts/build.sh --package-only` passes with the new target in the umbrella.
3. `DocumentCore` compiles unchanged (the new dependency edge is additive).
4. Full `swift test -Xswiftc -warnings-as-errors` passes.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'ShareTokenTests|RelayProtocolTests|DeviceIdentityTests'
Scripts/build.sh --package-only
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 3 — the relay worker
**Goal:** `Relay/` contains a deployable Cloudflare Worker implementing wire contracts A and
B with a vitest suite; nothing outside `Relay/` changes.
**Depends on:** none — can start immediately (contracts are normative in this plan).
**Files to create:** `Relay/package.json`, `Relay/tsconfig.json`, `Relay/wrangler.toml`,
`Relay/src/index.ts`, `Relay/src/shareHub.ts`, `Relay/src/token.ts`,
`Relay/test/token.spec.ts`, `Relay/test/hub.spec.ts`, `Relay/test/http.spec.ts`,
`Relay/README.md`, `Relay/.gitignore` (node_modules, .wrangler).
**Files to modify:** none.
**Do NOT touch:** anything outside `Relay/` — the Swift package, docs, scripts are other
agents' ground.
**Context it needs:** wire contracts A and B above are the whole spec — implement them
exactly, including: `hello` replaces the link table and must complete before routing;
`expectsReply:false` for id-less frames with HTTP 202; 404 for unknown/revoked/malformed
tokens (uniform — no oracle); the exact offline JSON-RPC error body with the caller's `id`
echoed; 120 s response timeout; `Mcp-Session-Id` minted on initialize responses and ignored
inbound; GET 405 / DELETE 200 / OPTIONS 204; 4 MB request cap; TOFU device auth with 4401
close; ping/pong 30 s; log ids only, never bodies or tokens.
**Implementation notes:** DO class `ShareHub`, one instance per `deviceId`
(`idFromName(deviceId)`); use WebSocket Hibernation API
(`state.acceptWebSocket`, `webSocketMessage`) so an idle Mac costs nothing; pending requests
in a `Map<requestId, {resolve, timer}>`; DO storage keys: `secretHash`, `link:<tokenHashHex>`
→ `{linkId, revoked}`. `src/token.ts` exports `parseToken(path)` returning
`{deviceId, token}` or null (regex per D5) and `sha256Hex`. Tests via
`@cloudflare/vitest-pool-workers`; pin dependency versions in `package.json`; Node ≥ 20
noted in `Relay/README.md` along with `npm ci && npm test` and the deploy user-step
(`npx wrangler deploy`). If `npm` is unavailable on the machine, still deliver the suite and
say so in the report — do not delete tests to go green.
**Acceptance criteria:**
1. `cd Relay && npm ci && npm test` passes (or the environment lacks node and the report says
   exactly that, with the suite complete).
2. Token spec: valid parses; wrong prefix/length → null; hashes match a fixed test vector
   shared with `ShareTokenTests` (write the vector in a comment: token string → expected
   hex).
3. HTTP spec: unknown token → 404 empty; revoked → 404; device offline → 200 with the exact
   `-32000` body and echoed id; notification → 202; GET → 405; DELETE → 200.
4. Hub spec: TOFU registers then rejects a wrong secret with 4401; `hello` reconciliation
   revokes a link the app no longer lists; request/response round-trip through a fake agent
   socket; timeout produces the offline error.
5. `git diff --stat` shows only `Relay/` paths.
**Verification commands:**
```bash
cd Relay && npm ci && npm test
git diff --stat
```

### Agent 4 — read-only serve mode
**Goal:** `opensheets-mcp --read-only` serves only read-only tools, and the registry filter
is a tested, public API.
**Depends on:** none — can start immediately.
**Files to create:**
`Packages/OpenSheetsCore/Tests/SheetMCPTests/ReadOnlyServeTests.swift`.
**Files to modify:**
`Packages/OpenSheetsCore/Sources/SheetMCP/Tools/ToolRegistry.swift` — add
`public static var readOnly: ToolRegistry` (filter `standard` on `schema.isReadOnly`);
`Packages/OpenSheetsCore/Sources/SheetMCP/CLI/CommandLine.swift` — `serve` accepts an
optional `--read-only` flag (`:636-664` region), choosing the registry; unknown serve
arguments → exit 2 usage error like the existing pattern (`:8-19`);
`CLI/opensheets-mcp/main.swift` — pass arguments through:
`OpenSheetsCLI.run(arguments: ["serve"] + CommandLine.arguments.dropFirst())`;
`Packages/OpenSheetsCore/Sources/SheetMCP/CLI/CLISurface.swift` — only if the surface table
documents `serve` flags (check first; if the table doesn't model flags, leave it alone and
say so).
**Do NOT touch:** `MCPServer.swift` (no transport changes); `ShippedBinaryTests.swift`
(pinned); any `Tools/*.swift` tool definition; `Package.swift` (Agent 2).
**Context it needs:** registry shape (`ToolRegistry.swift:97-150`), `isReadOnly` on schemas
(`ToolSchema.swift:60-148`), serve construction (`CommandLine.swift:636-664`), shim
rationale — logic stays in `OpenSheetsCLI` because executable targets can't be imported by
tests (`Package.swift:120-124`), exit codes (`CommandLine.swift:8-19`), existing serve tests
to imitate in `Tests/SheetMCPTests/` (drive `MCPServer` with the filtered registry through
`handle`, the `ProtocolTests.swift:52` pattern).
**Implementation notes:** do not hand-list tool names in the filter — filter on the
annotation so a future tool self-classifies. In `ReadOnlyServeTests`, assert both directions:
every tool in `readOnly` has `isReadOnly == true`, and specific canaries (`read_range`,
`describe` present; `write_range`, `delete_file` absent). Add one `tools/call` through
`handle` proving a write tool on the read-only registry returns JSON-RPC `methodNotFound`
(the unknown-tool path, `MCPServer.swift:168-187`).
**Acceptance criteria:**
1. `swift test --filter ReadOnlyServeTests` passes with ≥ 5 tests including the canaries and
   the `methodNotFound` call.
2. `opensheets-mcp` with no args behaves exactly as before (existing `ProtocolTests` and
   `ShippedBinaryTests` pass unedited).
3. `serve --read-only` + an unknown flag exits 2.
4. Full package build/test green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'ReadOnlyServeTests|ProtocolTests'
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 5 — GlassUI: Cloud status and share-link rows
**Goal:** GlassUI exposes `CloudShareStatus`, `ShareLinkRowModel`, `ShareLinkRowAction`, and
`ShareLinkRow`, tested at the model level, drawing no glass surface.
**Depends on:** none — can start immediately (contracts in "Frontend" above).
**Files to create:**
`Packages/OpenSheetsCore/Sources/GlassUI/Chrome/CloudShareRows.swift`.
**Files to modify:**
`Packages/OpenSheetsCore/Tests/GlassUITests/ComponentModelTests.swift` — append a
`Cloud share` suite region following the existing per-component regions (`:255-310` is the
template).
**Do NOT touch:** `Sidebar.swift` (no sidebar panel in v1); `Gallery/*` and
`AppearanceSnapshotTests.swift` (no surface ⇒ no catalog/golden entries, the
`FileExplorer.swift:5-15` rule); `App/*` (Agent 8); `ClaudeClientRow.swift`.
**Context it needs:** `ClaudeClientRow.swift` end to end (model/status/action/view split,
`@Environment(\.glassAppearance)`, `spokenSummary`); `SnapshotBrowser.swift:171-242` row
anatomy; tokens: `DS.Space`, `DS.Text.path/control/controlEmphasis/caption`,
`DS.Chrome.secondary/tertiary`, `DS.Signal.errorInk`, `AgentDot` (`Atoms.swift:16-66`),
`.hoverTitle` (`Atoms.swift:247-264`); the lint rules (no numeric padding/spacing literals,
no colour literals here, springs only, no global state); status words are identity, captions
are App policy (`ClaudeClientRow.swift:36-38`, `LauncherScene.swift:258-261`).
**Implementation notes:** exact type shapes are locked in "Frontend" above. `ShareLinkRow`
takes `model: ShareLinkRowModel` and `perform: (ShareLinkRowAction) -> Void`; copy is an
icon-only bordered small button with `.accessibilityLabel("Copy share link")`; revoke/remove
live in a `.contextMenu` with `role: .destructive`; a revoked row renders name struck-through
`DS.Chrome.tertiary` plus the status word `Revoked`; rejection renders the
`Label`/`exclamationmark.circle`/`errorInk` idiom (`ClaudeClientRow.swift:99-186`).
**Acceptance criteria:**
1. `swift test --filter ComponentModelTests` passes including the new suite: every
   `CloudShareStatus` case has a distinct non-empty `label`; every case has a `signal`;
   row-model equality; a `CaseIterable` count pin.
2. `swift test --filter GlassLintTests` passes (no padding literals, no colours, no global
   state introduced).
3. No changes under `Gallery/`, no golden-file churn (`git diff --name-only` shows exactly
   the two files owned).
4. Full package build/test green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors --filter 'ComponentModelTests|GlassLintTests'
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
git diff --name-only
```

### Agent 6 — SheetShare engine: relay client, link bridge, orchestration
**Goal:** `RelayClient`, `LinkBridge`, and `CloudShareEngine` exist and are proven against a
fake socket and the real built binary.
**Depends on:** Agents 1 (ShareLinkStoring), 2 (target + protocol + token), 4
(`--read-only`).
**Files to create:**
`Packages/OpenSheetsCore/Sources/SheetShare/RelayClient.swift`,
`Packages/OpenSheetsCore/Sources/SheetShare/LinkBridge.swift`,
`Packages/OpenSheetsCore/Sources/SheetShare/CloudShareEngine.swift`,
`Packages/OpenSheetsCore/Tests/SheetShareTests/RelayClientTests.swift`,
`Packages/OpenSheetsCore/Tests/SheetShareTests/LinkBridgeTests.swift`.
**Files to modify:** none (all new files land in the target Agent 2 created — no manifest
edit).
**Do NOT touch:** `Package.swift`; `Sources/DocumentCore/*` (Agent 7); `Sources/SheetMCP/*`;
Agent 2's files (extend by adding files, not editing theirs).
**Context it needs:** wire contract A and D8 above (normative); `RelaySocket` seam — define
`public protocol RelaySocket: Sendable` (`connect(url:headers:)`, `send(String)`,
`receive() async throws -> String`, `close()`) with the `URLSessionWebSocketTask` production
conformance in the same file, fake in tests; reconnect/backoff/generation shape from
`FileWatcher.swift:56-129,251-270`; subprocess conversation + staged home from
`ShippedBinaryTests.swift:67-151` and scratch-dir rule (`Support.swift:11-14`); binary
discovery is **injected** (`binaryURL: URL` on the engine/bridge — production value comes
from Agent 7; tests resolve the built product the way `ShippedBinaryTests.swift:35-52`
does); frame cap 32 MB (`StdioTransport.swift:156`); revocation is re-read per request
through `ShareLinkStoring.activeRecord(tokenHash:)`/`record(id:)` — never a cached list (the
`AppModel.swift:447-449` rule, restated for links); `last_used_at` via `touchLastUsed`.
**Implementation notes:** `LinkBridge` is an actor keyed by `linkId` holding
`{Process, stdin, stdout, lastUsedAt}`; spawn args `["--read-only"]` iff mode is
`.readOnly` (the shim prepends `serve`); an id-bearing frame writes then awaits exactly one
stdout line (D8) with a per-call timeout (90 s, injectable — under the relay's 120 s);
id-less frames write and return. Idle reap via a repeating task with injectable interval.
`CloudShareEngine` (actor) owns the event loop: relay `request` → look up record by
`linkId` → refuse if missing/revoked (send `response(status:"error")`) → bridge →
`response`. It also exposes `setLinks`/`upsert` pushes and emits an `AsyncStream` of
status/link-activity events for the service layer. Errors map to existing `SheetError`
cases; a dead subprocess is respawned on the *next* request, not eagerly.
**Acceptance criteria:**
1. `swift test --filter RelayClientTests` passes: hello-first ordering, backoff schedule
   under injected timings (asserted delays), generation counter discards a stale socket's
   events, `stop()` closes and stops reconnecting.
2. `swift test --filter LinkBridgeTests` passes against the real binary (Issue-and-return
   skip if unbuilt, the `ShippedBinaryTests.swift:173-176` idiom): initialize round-trip;
   read-only spawn's `tools/list` lacks `write_range`; notification produces no stdout
   await; idle reap terminates the process; revoked link refused without spawning; crash
   yields `response(status:"error")` and a respawn serves the next call.
3. A revoke recorded in the DB is honored on the very next request with no restart.
4. Full package build/test green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'RelayClientTests|LinkBridgeTests'
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 7 — app wiring: CloudShareService, AppModel, flags, entitlements
**Goal:** the app owns a flag-gated `CloudShareService` on `AppModel` with the kill-switch
bar met, the new flag registered, and the entitlements updated.
**Depends on:** Agent 6 (engine API), Agents 1, 2, 5 (types).
**Files to create:**
`Packages/OpenSheetsCore/Sources/DocumentCore/CloudShareService.swift`,
`Packages/OpenSheetsCore/Tests/DocumentCoreTests/CloudShareServiceTests.swift`.
**Files to modify:**
`Packages/OpenSheetsCore/Sources/DocumentCore/AppModel.swift` —
`@ObservationIgnored public private(set) var share: CloudShareService?` built in `init`
(`:163-186`) iff the flag allows; `cloudShareForThisInstance: Bool?` beside `:152`;
`Flags.cloudShareEnabled` (`OSFlagCloudShare`, default **false**) in the `Flags` enum
(`:581-624`) with a comment in the `handshakeEnabled` voice;
`App/Flags.swift` — add the flag to `summary` (`:19-30`);
`App/OpenSheetsApp.swift` — nothing unless a one-line start hook is required; the service
starts itself from `AppModel.init` when enabled — if a hook is unavoidable, it is one line
and the report says why;
`Config/OpenSheets.entitlements` — add `com.apple.security.network.client` `true` and
rewrite the `:23-25` comment to name Cloud Share as the argued exception, honestly.
**Do NOT touch:** `App/LauncherScene.swift` (Agent 8); `Sources/SheetShare/*` (Agent 6);
`project.pbxproj`; `ClaudeConnector.swift`.
**Context it needs:** service-ownership precedent (`AppModel.swift:71-76,168`); kill-switch
bar and its structural test (`AppModel.swift:600-613`,
`HandshakePublisherTests.theKillSwitchWithholdsBothHalves` — imitate the assertion style);
per-instance override consumption (`:431`); static status mapping
(`AppModel.swift:534-545`); binary discovery closure — copy the
`ClaudeConnector.serverBinary` approach (`ClaudeConnector.swift:118-146`): injected
`bundledServerURL: () -> URL?` defaulting to
`Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp")` with the
`/usr/local/bin/opensheets-mcp` fallback; `OSCloudShareEnabled` UserDefaults key read fresh;
`OSCloudRelayURL` override for the relay origin; lifecycle must NOT hang off
`OpenActions.workspaceClosed` (`OpenSheetsApp.swift:389-399` is the wrong hook — the
service outlives windows).
**Implementation notes:** `CloudShareService` is `@MainActor @Observable`; it owns a
`CloudShareEngine` + `RelayClient` off-main and mirrors `status: CloudShareStatus`,
`links: [ShareLinkRecord]` for the UI; `createLink(name:mode:)` mints via `ShareToken`,
inserts, pushes `link_upsert`, returns the record (App layer copies the URL);
`revoke(id:)`/`remove(id:)`/`setEnabled(_:)`/`refresh()`. Static
`CloudShareService.status(for:) -> CloudShareStatus` maps engine state — pure, total,
tested as a table. Flag off ⇒ `AppModel.share == nil` and constructing `AppModel` performs
zero SheetShare work (no Keychain, no DB read of `share_link`) — assert with a counting fake.
**Acceptance criteria:**
1. `swift test --filter CloudShareServiceTests` passes: kill-switch structural test; status
   table total over all engine states; createLink round-trip against an in-memory store +
   fake engine; revoke flips and pushes; per-instance override wins over the flag.
2. Flag defaults off: a fresh `AppModel` in tests has `share == nil` without setting
   anything.
3. `Flags.summary` mentions the new flag (string assertion in an existing-flag-test style if
   one exists; otherwise the report shows the line).
4. Entitlements file still parses (`plutil -lint Config/OpenSheets.entitlements`) and
   contains the new key; `Scripts/build.sh` full app build passes and the bundle still
   embeds the MCP binary.
5. Full package build/test green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors --filter CloudShareServiceTests
plutil -lint Config/OpenSheets.entitlements
Scripts/build.sh && APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/OpenSheets-*/Build/Products/Debug/OpenSheets.app 2>/dev/null | head -1) && test -x "$APP/Contents/MacOS/opensheets-mcp"
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 8 — Settings ▸ Cloud section
**Goal:** the Cloud section renders in Settings behind the flag, wired to
`CloudShareService`, with create/copy/revoke/remove flows and inline failures.
**Depends on:** Agents 5 (rows), 7 (service).
**Files to create:** none.
**Files to modify:** `App/LauncherScene.swift` only — insert `Section("Cloud")` after the
Claude section (`:220`); add the create-row state, `rejections` keyed by link id, the
`rowModel(for: ShareLinkRecord)` translator, and the `perform` handler (clipboard writes,
`service.createLink`, `revoke`, `remove`); extend `.onAppear` (`:229-232`) with
`app?.share?.refresh()`.
**Do NOT touch:** GlassUI (Agent 5's components are final — if a prop is missing, report,
don't edit); `AppModel.swift`/`CloudShareService.swift` (Agent 7); `SidebarColumn.swift`
(no sidebar panel in v1); any other App file.
**Context it needs:** the whole Settings idiom (`LauncherScene.swift:181-341`): `@AppStorage`
for `OSCloudShareEnabled`; captions are written here — use the exact copy from "User flow"
above (empty-state caption, the anyone-with-this-link warning, offline detail sentences,
revocations-sync detail); rejection idiom (`:190-193,333-334`); clipboard idiom
(`SidebarColumn.swift:207-212`); lint: no numeric padding/spacing literals in `App/` either;
`.formStyle(.grouped)` width 460 is existing — the section must lay out within it; the
section renders only when `Flags.cloudShareEnabled` (absent means absent).
**Implementation notes:** translator maps `ShareLinkRecord` → `ShareLinkRowModel`
(relative dates via `RelativeDateTimeFormatter`; `modeWord` from `ShareLinkMode`;
`urlDisplay` is the full URL string — the row middle-truncates). Create button disabled
until the trimmed name is 1–64 chars; on success clear the field and write the URL to
`NSPasteboard` (clear-then-set); on `SheetError` set `createRejection = error.message`.
Revoke needs no confirmation dialog (no house precedent for one) — the destructive role +
revoked-row visibility is the affordance, and Remove is only offered on revoked rows.
**Acceptance criteria:**
1. `swift build` of the package and `Scripts/build.sh` (full app) pass.
2. `swift test --filter GlassLintTests` passes (the scan covers `App/`).
3. With `OSFlagCloudShare` unset, the compiled Settings form contains no "Cloud" section
   (verified by code inspection in the report — the pane is screen-unverified and Agent 9
   records that in §12).
4. Every user-facing sentence in the section appears in `App/LauncherScene.swift` (none in
   GlassUI) — grep proof in the report.
5. Full package test suite green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors --filter GlassLintTests
Scripts/build.sh
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 9 — documentation truth pass
**Goal:** every document tells the new truth, in the house voice, markdown only.
**Depends on:** Agents 1–8 merged (documents what actually shipped).
**Files to create:** `docs/cloud-share.md` (owner + recipient guide: what a link grants, the
threat model sentences from "The policy line", per-client add instructions with the plan
gating the research found, offline behavior, revocation, the relay-deploy user step).
**Files to modify:**
`README.md` — the "We deliberately don't" table row about a hosted bridge becomes a "We
build" row stated precisely ("an opt-in, revocable relay that routes bytes and grants
nothing — see docs/cloud-share.md"); Layout block gains `Relay/` and `SheetShare`; status
paragraph updated honestly (flag off, relay undeployed, pane screen-unverified);
`PLAN.md` — §0 table + `:8` narrative annotated the way past corrections are (kept text +
dated correction, see the `:509-513` precedent), §12 Integrations gains the relay;
`DOCUMENTATION.md` — §1 table; §2.6 flag table (+`OSFlagCloudShare`); §4/§4.1 diagram +
target table (+`SheetShare`, new counts derived by running the commands the doc's header
demands); **§5.9 rewritten** to draw the new line (relay-as-pipe, double revocation,
SheetMCP-still-offline — the five numbered points from "The policy line"); §9 gains a
"Cloud Share trust boundary" subsection; §12.1 gains the open gates (relay undeployed,
Settings ▸ Cloud screen-unverified, Gemini Spark unverified, claude.ai org-admin flow may
lack auth-None); §13.1 repo layout (+`Relay/`); `docs/mcp.md` — the stdio-only claim
(`:94-97`) updated to name the bridge and where enforcement still lives;
`docs/agents/T-cloud-share-tracking.md` (new) — ownership record in the
`T-tabs-tracking.md` format (new-file→owner table + "things worth knowing").
**Do NOT touch:** any source file, any test, `Relay/src` — `git diff --stat` must show only
`.md` files.
**Context it needs:** the doc house rule — every number derived by running a command
(`DOCUMENTATION.md:14-17`); section map with line anchors (recon table in this plan's
"What exists today"); the §9.5 precedent for redrawn lines; the voice ("be honest about
staleness"); client compatibility findings + uncertainties (the matrix in "What exists
today" and the sources in "Integrations") — including stating plainly which client paths are
unverified.
**Acceptance criteria:**
1. `git diff --stat` lists only markdown files.
2. §5.9's old argument is preserved (quoted or summarized) and answered, not deleted.
3. The README non-goal row is updated and `docs/cloud-share.md` exists with all five policy
   sentences (including the two "cannot promise" ones) present.
4. §12.1 lists the four open gates named above.
5. Tool-count and target-count claims re-derived (commands shown in the commit body).
**Verification commands:**
```bash
git diff --stat
grep -n "hosted bridge" README.md DOCUMENTATION.md docs/mcp.md
grep -rn "OSFlagCloudShare" DOCUMENTATION.md
```

### Agent 10 — end-to-end share tests
**Goal:** one suite proves the full local stack — fake relay transport → engine → real
subprocess → real staged DB — behaves per the user flow.
**Depends on:** Agents 1, 2, 4, 6 (not 7/8 — it drives the engine directly).
**Files to create:**
`Packages/OpenSheetsCore/Tests/SheetShareTests/EndToEndShareTests.swift`.
**Files to modify:** none.
**Do NOT touch:** production sources; other agents' test files.
**Context it needs:** the two-store staging harness (`Tests/SheetMCPTests/Support.swift:46-56`
— `.app` store grants, engine runs against the same DB), staged home + real binary
(`ShippedBinaryTests.swift:35-151`), wire contract A (drive the engine by injecting relay
messages through the fake `RelaySocket`), fixture workbooks under `Fixtures/`
(`FixtureLibrary` in TestSupport).
**Implementation notes:** scenario tests, named as claims: (1) "A shared link answers
describe" — create link via the store, hello, inject `request` with an `initialize` then
`tools/call describe` on a granted fixture, assert the response frames parse and carry no
error; (2) "A read-only link does not advertise write tools"; (3) "A revoked link answers
nothing" — revoke in DB, inject request, assert `response(status:"error")` and no
subprocess spawn; (4) "An id-less frame produces no response"; (5) "A second request reuses
the subprocess" (pid stable via one `get_selection`-free probe — compare spawn counts
through an injected spawn-counting seam if pid is unreachable). Use `.serialized` — real
subprocesses.
**Acceptance criteria:**
1. `swift test --filter EndToEndShareTests` passes locally after `swift build` (skip-with-
   Issue when the binary is missing, the `:173-176` idiom).
2. Scenario (1) asserts on actual `describe` output text (fixture-derived), not just "no
   error".
3. Full package test suite green with warnings-as-errors.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter EndToEndShareTests
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
```

### Agent 11 — integration and final verification
**Goal:** the seams reconcile, every gate runs, and the report states pass/fail per
acceptance criterion of every agent — listing anything unmet rather than declaring success.
**Depends on:** everything.
**Files to create:** none. **Files to modify:** only what reconciliation demands (imports,
duplicate helpers, stubs) — each such edit named in the report.
**Do NOT touch:** scope beyond reconciliation; no new features.
**Context it needs:** this plan, end to end.
**Checklist:**
1. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors` — full suite.
2. `Scripts/build.sh --package-only`, then `Scripts/build.sh`, then verify the embedded
   binary is executable and `--read-only`-capable:
   `"$APP/Contents/MacOS/opensheets-mcp" --read-only < /dev/null` exits 0-or-clean.
3. `cd Relay && npm ci && npm test` (report environment honestly if node is absent).
4. `swiftformat --lint . && swiftlint lint --strict` from the package root if the pinned
   tools are installed; otherwise say so (`DOCUMENTATION.md:2740-2741` precedent).
5. Walk the Phase-2 user flow against the code: for steps 1–8, name the file:line that
   implements each sentence of copy and each state; flag any sentence that exists in the
   plan but not the code.
6. Verify every permission row in the "Permissions" table is enforced at the named layer
   (cite the test or the line).
7. Verify rollout prerequisites: flag default off; placeholder relay origin clearly marked;
   `Flags.summary` updated; entitlements linted; no `TODO` placeholders
   (`grep -rn "TODO" Packages/OpenSheetsCore/Sources App Relay/src`).
8. Confirm the docs pass: `git log --stat` shows Agent 9 touched only markdown; §12 gates
   present.
9. Report: a table of every agent's acceptance criteria × pass/fail with evidence, then the
   open user steps (deploy relay, bake URL, screen-verify, flip flag).
**Verification commands:** the checklist's, literally.

---

## Execution graph

| Wave | Agents | Parallel-safe? | Why the boundary exists |
| --- | --- | --- | --- |
| 1 | A1 (store), A2 (SheetShare scaffold), A3 (relay), A4 (read-only serve), A5 (GlassUI) | Yes — five disjoint file sets | These are the contracts and leaves everything else compiles against: table + protocol types + relay + registry flag + row components |
| 2 | A6 (engine) | n/a (solo) | Needs A1's store protocol, A2's target/protocol/token, A4's `--read-only` |
| 3 | A7 (app wiring), A10 (E2E) | Yes — disjoint files | Both need A6's engine; A10 deliberately bypasses A7 |
| 4 | A8 (Settings UI), A9 (docs) | Yes — `App/LauncherScene.swift` vs markdown only | A8 needs A5's components and A7's service; A9 documents what actually merged |
| 5 | A11 (integration) | n/a (solo) | Runs after every seam exists |

No file is owned by two agents in any wave. Shared-file forcings: `Package.swift` → A2 only
(wave 1); `AppModel.swift` + `App/Flags.swift` + entitlements → A7 only;
`App/LauncherScene.swift` → A8 only; `ComponentModelTests.swift` → A5 only;
`Database.swift`/`WorkspaceGrants.swift` → A1 only; `ToolRegistry.swift`/`CommandLine.swift`
/shim → A4 only; everything under `Relay/` → A3 (then untouched); markdown → A9 only.
Critical path: A2 → A6 → A7 → A8 → A11 (5 waves; 11 agents total).

Branches: umbrella `feature/cloud-share`; agents `agent/a1-share-link-store`,
`agent/a2-sheetshare-scaffold`, `agent/a3-relay-worker`, `agent/a4-read-only-serve`,
`agent/a5-glassui-cloud-rows`, `agent/a6-share-engine`, `agent/a7-cloud-service`,
`agent/a8-settings-cloud`, `agent/a9-cloud-docs`, `agent/a10-share-e2e`,
`agent/a11-integration`.
