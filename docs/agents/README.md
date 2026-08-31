# Agent briefs — OpenSheets v0.1

Read [`../../PLAN.md`](../../PLAN.md) first, especially **§13.1 Rules of engagement**. Then read
only your own brief.

| # | Agent | Wave | Runs with | Blocked by | Primary target |
| --- | --- | --- | --- | --- | --- |
| [A0](A0-foundation.md) | Foundation & interface freeze | 0 | — alone | — | scaffold + `SheetModel` |
| [A1](A1-xlsx-read.md) | XLSX reader + ZIP read + hardening | 1 | A2–A7 | A0 | `SheetFormat`, `MiniZip` |
| [A2](A2-xlsx-write-csv.md) | XLSX surgical writer + CSV/TSV | 1 | A1,A3–A7 | A0 | `SheetFormat`, `MiniZip` |
| [A3](A3-formula-engine.md) | Formula engine | 1 | A1,A2,A4–A7 | A0 | `SheetFormula` |
| [A4](A4-gridkit.md) | Virtualised grid renderer | 1 | A1–A3,A5–A7 | A0 | `GridKit` |
| [A5](A5-glassui.md) | Glass design system + chrome | 1 | A1–A4,A6,A7 | A0 | `GlassUI` |
| [A6](A6-sheetstore.md) | File sync, snapshots, grants, DB | 1 | A1–A5,A7 | A0 | `SheetStore` |
| [A7](A7-fixtures-testing.md) | Fixture corpus + test/perf infra | 1 | A1–A6 | A0 | `Fixtures`, `TestSupport` |
| [A8](A8-app-shell.md) | App shell & integration | 2 | A9 | A1–A7 | `App/` |
| [A9](A9-mcp-cli.md) | MCP server + CLI | 2 | A8 | A1,A2,A3,A6 | `SheetMCP`, `CLI/` |
| [A10](A10-integration-release.md) | E2E, perf gate, packaging, release | 3 | — alone | A8,A9 | everything |

**Model change requests** go in [`MODEL-CHANGE-REQUESTS.md`](MODEL-CHANGE-REQUESTS.md) — never
edit `SheetModel` yourself after Wave 0.

## Per-feature tracking

The table above is the original v0.1 build. Features built since then get their own plan under
`.claude/plans/` and their own tracking page here — who owned which new file, and what the next
person to touch it needs to know. **Their agent numbering is local to the feature and does not
relate to the A0–A10 above.**

| Feature | Tracking page | Plan |
| --- | --- | --- |
| File tabs & change tracking | [`T-tabs-tracking.md`](T-tabs-tracking.md) | `.claude/plans/file-tabs-and-change-tracking.md` |
| Cloud Share | [`T-cloud-share-tracking.md`](T-cloud-share-tracking.md) | `.claude/plans/cloud-share-remote-mcp.md` |
