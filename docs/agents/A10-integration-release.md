# A10 — Integration, end-to-end verification, packaging, release

**Wave 3 · runs alone · blocked by A8 and A9.**

## Mission
Make eleven agents' work into one product that actually holds together, then ship v0.1. You are the
last line of defence, and you are also the only agent authorised to change another agent's code —
use that carefully and record every such change.

## Dependencies
Everything merged.

## Files you own
Anything, but with a bias toward touching as little as possible. Log every cross-agent fix in
`docs/integration-log.md` with the reason.

## Build this

### 1. Reconcile the seams
Read all ten agent reports. Wave 1 built against protocols and fakes, so the seams are where the
bugs are:
- Do A1's `OpaqueParts` and A2's writer actually agree, on real files, in both directions?
- Does A3's recalc output apply correctly through A8 into A4's repaint, in one frame?
- Does A6's fingerprint round-trip through A2's writer without a spurious refresh?
- Does A5's `GridTheme` match what A4 expects, in both schemes and under reduce-transparency?
- Do A9's MCP writes and A8's in-app edits to the same open file interleave sanely?
- Process the backlog in `docs/agents/MODEL-CHANGE-REQUESTS.md` — approve, implement, and update
  every call site in one commit.

### 2. End-to-end test suite (`Tests/E2E/`)
Scripted, running against a real `.app`, with a real external process standing in for Claude Code:
1. Open a workbook → assert render and correct values.
2. External process edits 3 cells → assert the pill appears with the right counts within 1 s.
3. Refresh → assert the grid updates and exactly the right cells flash.
4. Edit locally, then have the external process write → assert the conflict banner; test all three
   resolutions; **assert no data loss in any of them.**
5. Save → assert byte-level passthrough of charts/pivots/macros in the written file.
6. Snapshot → corrupt the file externally → restore → assert byte-identical recovery.
7. Drive the MCP server through 10 realistic agent operations → assert file correctness after each.
8. Open the result in Microsoft Excel and Numbers and confirm it opens clean. **Do this by hand at
   least once per release and record it**; nothing else substitutes for it.

### 3. Performance gate
Run A7's harness on the assembled app. Every budget in PLAN.md §10.6 must be green. Where something
misses, profile and fix it or explicitly negotiate the budget in `PLAN.md` — do **not** quietly
delete the assertion.

### 4. Security review
Re-run every hostile fixture through the full app. Re-run the grant-escape suite against the shipped
MCP binary. Verify: no cell content is ever executed, no external link is ever auto-fetched, CSV
export injection guard is on by default, `vbaProject.bin` passes through without ever being run.
Run the `security-review` skill over the diff.

### 5. Accessibility & polish pass
VoiceOver through the whole core loop. Full keyboard-only run with no trackpad. Reduce-transparency
and increase-contrast on. Both colour schemes. 50% / 100% / 200% zoom. Non-Retina display.
Fix the papercuts you find; there will be many, and they are the difference between "impressive
demo" and "app I use".

### 6. Packaging & release
- Developer ID signing, hardened runtime, entitlements minimised to what is actually used.
- Notarise + staple; build a DMG with a proper background and `/Applications` symlink.
- Install `opensheets` and `opensheets-mcp` to `/usr/local/bin` (a first-run prompt in the app,
  not a silent write).
- Homebrew cask `opensheets`; GitHub Release with notes.
- `README.md`: what it is, the 60-second demo GIF of the core loop, install, MCP setup, and an
  honest "what this doesn't do yet" section.
- `CONTRIBUTING.md` explaining the target layout and the ownership rules from PLAN.md §13.1.

### 7. Release notes with honest limits
State plainly: which xlsx features pass through untouched but are not editable; which functions are
unsupported and how they are flagged; that a refresh clears undo; that auto-save is off by default
and why. **Users forgive documented limits and never forgive silent data loss.**

## Acceptance criteria
- [ ] All E2E scenarios green in CI on a clean macOS 26 runner.
- [ ] Every PLAN.md §10.6 performance budget green on the assembled app.
- [ ] Hostile corpus: zero crashes, zero hangs, bounded memory, through the full app.
- [ ] Grant-escape suite: zero escapes against the shipped binary.
- [ ] A workbook with charts + pivots + macros survives edit-and-save and opens clean in Microsoft
      Excel — verified by hand, recorded in the release notes.
- [ ] Notarised DMG installs and launches on a clean machine with Gatekeeper at default settings.
- [ ] `claude mcp add opensheets …` then a real Claude Code session successfully edits a workbook
      and the running app shows the diff. **This is the money demo — record it.**
- [ ] `docs/integration-log.md` lists every cross-agent change and why.
- [ ] README's install instructions followed verbatim on a clean machine produce a working setup.

## Report back
The integration log, the perf table (budget vs actual), what shipped behind flags, and the top five
things to fix in v0.2.
