# opensheets-relay

The hosted half of Cloud Share: a Cloudflare Worker that gives a Mac running
OpenSheets a public HTTPS street address. It routes bytes and grants nothing —
grant enforcement, the deny-list, previews, and snapshots all keep running in
the local `opensheets-mcp` subprocess on the owner's Mac.

One Durable Object per device (`ShareHub`, SQLite-backed, WebSocket
hibernation) holds the Mac's outbound socket and a table of link-token
*hashes*. Storage never sees a plaintext token, a frame body, or any
spreadsheet content, and logs carry ids only.

The wire contracts (app ⇄ relay WebSocket, client ⇄ relay HTTP) are normative
in `.claude/plans/cloud-share-remote-mcp.md` at the repo root; `src/token.ts`
carries the token grammar and the test vector shared with the Swift suite.

## Test

Requires Node ≥ 20 (developed against v23).

```bash
npm ci
npm test          # vitest, runs inside the Workers runtime (miniflare)
npm run typecheck
```

The lockfile was generated with `--legacy-peer-deps` to sidestep an npm 10
arborist crash while resolving vitest peers; `npm ci` replays it cleanly. If a
fresh `npm install` hits `Cannot read properties of null (reading 'edgesOut')`,
add `--legacy-peer-deps`.

## Deploy (one-time user step)

```bash
npx wrangler login   # opens the browser for Cloudflare OAuth
npx wrangler deploy
```

`wrangler deploy` prints the worker origin
(`https://opensheets-relay.<account>.workers.dev`). That origin is what the app
compiles in as `CloudShareConfiguration.standard` — until it is baked in, the
`OSCloudRelayURL` user-default overrides it for development.

Tearing the worker down (`npx wrangler delete`) kills every link with a clean
"OpenSheets is offline" error — that is the documented big red switch.

## Local development

```bash
npm run dev        # wrangler dev on localhost
```

Note the production response timeout is 120 s (`RESPONSE_TIMEOUT_MS` in
`wrangler.toml`); the vitest config overrides it to 500 ms so timeout paths are
testable.
