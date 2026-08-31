# A1–A11 — Cloud Share

The feature plan is [`.claude/plans/cloud-share-remote-mcp.md`](../../.claude/plans/cloud-share-remote-mcp.md).
Eleven agents, five waves; this page is the record of **who owns what**, so the next person to touch
one of these files knows which contract they are standing on.

> **These A-numbers are local to this feature.** They are not the `A1`–`A10` of the original v0.1
> briefs in this directory — `A1-xlsx-read.md` and the rest, indexed in
> [`README.md`](README.md). Same letter, unrelated numbering, and the two never appear in the same
> sentence anywhere but this one. Cloud Share's A5 is the GlassUI rows; v0.1's A5 was the whole
> design system.

The user-facing guide is [`docs/cloud-share.md`](../cloud-share.md).

| Agent | Wave | Brought |
| --- | --- | --- |
| A1 | 1 | the `share_link` table, and our own store on the deny-list |
| A2 | 1 | the `SheetShare` target: share tokens, wire contract A, device identity |
| A3 | 1 | the relay worker under `Relay/` — implemented by the orchestrator, not a separate agent |
| A4 | 1 | `serve --read-only`, a registry filtered on the schema's own annotation |
| A5 | 1 | the cloud status words and the share-link row, with no glass surface of their own |
| A6 | 2 | the engine: relay socket, subprocess bridge, live revocation |
| A7 | 3 | `CloudShareService` on `AppModel`, the flag, and the entitlement argued for |
| A8 | 4 | Settings ▸ Cloud — **not merged.** Nothing in `App/` renders the rows yet |
| A9 | 4 | this page, `docs/cloud-share.md`, and the documentation truth pass |
| A10 | 3 | the end-to-end suite that drives the whole local stack |
| A11 | 5 | integration and final verification |

## New files, and their owner

| File | Owner |
| --- | --- |
| `Packages/OpenSheetsCore/Sources/SheetStore/ShareLinks.swift` | A1 |
| `Packages/OpenSheetsCore/Sources/SheetShare/ShareToken.swift` | A2 |
| `Packages/OpenSheetsCore/Sources/SheetShare/RelayProtocol.swift` | A2 |
| `Packages/OpenSheetsCore/Sources/SheetShare/DeviceIdentity.swift` | A2 |
| `Packages/OpenSheetsCore/Sources/SheetShare/CloudShareConfiguration.swift` | A2 |
| `Packages/OpenSheetsCore/Sources/SheetShare/RelayClient.swift` | A6 |
| `Packages/OpenSheetsCore/Sources/SheetShare/LinkBridge.swift` | A6 |
| `Packages/OpenSheetsCore/Sources/SheetShare/CloudShareEngine.swift` | A6 |
| `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/CloudShareRows.swift` | A5 |
| `Packages/OpenSheetsCore/Sources/DocumentCore/CloudShareService.swift` | A7 |
| `Relay/src/index.ts`, `src/shareHub.ts`, `src/token.ts` | A3 |
| `Relay/test/token.spec.ts`, `test/hub.spec.ts`, `test/http.spec.ts`, `test/support.ts` | A3 |
| `Relay/package.json`, `tsconfig.json`, `wrangler.toml`, `vitest.config.ts`, `README.md`, `.gitignore` | A3 |
| `Packages/OpenSheetsCore/Tests/SheetStoreTests/ShareLinkStoreTests.swift` | A1 |
| `Packages/OpenSheetsCore/Tests/SheetStoreTests/DenyListShareStoreTests.swift` | A1 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/ShareTokenTests.swift` | A2 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/RelayProtocolTests.swift` | A2 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/DeviceIdentityTests.swift` | A2 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/RelayClientTests.swift` | A6 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/LinkBridgeTests.swift` | A6 |
| `Packages/OpenSheetsCore/Tests/SheetShareTests/EndToEndShareTests.swift` | A10 |
| `Packages/OpenSheetsCore/Tests/SheetMCPTests/ReadOnlyServeTests.swift` | A4 |
| `Packages/OpenSheetsCore/Tests/DocumentCoreTests/CloudShareServiceTests.swift` | A7 |
| `docs/cloud-share.md` | A9 |

Modified rather than created: `Package.swift` (A2 — the target, its product, the umbrella membership
and the `DocumentCore → SheetShare` edge), `SheetStore/Database.swift` and
`SheetStore/WorkspaceGrants.swift` (A1), `SheetMCP/Tools/ToolRegistry.swift`,
`SheetMCP/CLI/CommandLine.swift`, `SheetMCP/CLI/CLISurface.swift` and `CLI/opensheets-mcp/main.swift`
(A4), `Tests/GlassUITests/ComponentModelTests.swift` (A5), `DocumentCore/AppModel.swift`,
`App/Flags.swift` and `Config/OpenSheets.entitlements` (A7).

## Things worth knowing before you edit any of it

**The read-only surface is nine tools, and it is pinned whole.**
`EndToEndShareTests.aReadOnlyLinkDoesNotAdvertiseWriteTools` asserts the exact list — `describe`,
`find`, `get_selection`, `list_files`, `list_snapshots`, `list_workspace`, `open_in_app`,
`read_range`, `reveal_range` — as a set equality rather than as a handful of absences. That is
deliberate: adding a tool to the read-only surface widens what every link already issued can do, so
it should have to fail a test rather than pass quietly. `filter` and `snapshot` are absent because
`filter` carries an `action: "delete"` and `snapshot` writes a restore point; both are correctly
annotated `isReadOnly: false`, and the fix — if a read-only link ought to offer them — is to split
the tool, not to special-case `ToolRegistry.readOnly`, which filters on the annotation and never on
a list of names.

**The deny-list grew by one directory, and that direction is one-way.**
`~/Library/Application Support/OpenSheets` is in `DenyList.standard` because share-link URLs live
there in plaintext beside the snapshots and the database — an agent that arrived through a link must
not be able to read the links. The list is only ever narrowed. The three pinned deny tests
(`WorkspaceGrantsTests`, `GrantEscapeTests`, `ShippedBinaryTests`) were not edited; the new assertion
is a new file, `DenyListShareStoreTests`.

**The wire contract is normative in the plan, not in either implementation.** Two stacks in two
languages implement wire contract A (app ⇄ relay WebSocket) and contract B (client ⇄ relay HTTP), and
neither is the specification — `.claude/plans/cloud-share-remote-mcp.md` is. `Relay/src/token.ts`
carries the token grammar and a test vector shared with `ShareTokenTests`, so both stacks are pinned
to hashing the same bytes. Change the contract in the plan first, or the two halves drift and the
only symptom is a socket that closes.

**`RelayClientTests` has a latent race, and it is A6's, not A7's.**
`theClientIsOnlineOnlyAfterTheRelayAcknowledgesHello` waits on `client.isOnline` and then asserts on
an event log that a *different* task drains, so the assertion can run before the drain does. A7's new
suite widened the window by being a load generator, and A7's fix was to mark its own file
`.serialized` rather than to reach into A6's. The race is still there. Whoever touches `RelayClient`
next should close it properly — wait on the event log, not on the flag.

**Mode is a process, not a policy.** A read-only link is enforced by spawning `opensheets-mcp` with
`--read-only`, so the smaller registry is built inside a separate process. The relay is never told
what mode a link has, and could not enforce it if it were. Anything that tries to make mode a runtime
check inside one shared server is a regression.

**Two gates, and both are structural.** `OSFlagCloudShare` (default off) gates *existence* —
`AppModel.share` is `nil`, so there is no object to start. `OSCloudShareEnabled` (default off) gates
*connecting* — the object exists so a pane can draw a switch, but `startIfEnabled()` returns before
an engine is built. `CloudShareServiceTests` hands the service counting fakes and asserts both counts
are zero with the toggle off: no `share_link` select, no Keychain read, no socket, no subprocess.
