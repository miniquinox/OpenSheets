import Foundation
import SheetMCP

//  opensheets-mcp — the MCP server, spawned by Claude Code.
//
//  Register it with:
//
//      claude mcp add opensheets -- /usr/local/bin/opensheets-mcp
//
//  Equivalent to `opensheets serve`, as its own binary so the registration line names something
//  that cannot do anything else. It speaks JSON-RPC 2.0 over newline-delimited stdio, and the
//  first thing `serve` does is take ownership of file descriptor 1 and point the process's
//  "standard output" at stderr — after that, no `print` anywhere in the process can corrupt the
//  protocol stream. See `ProtocolStream`.
//
//  Like `opensheets`, this binary does not link AppKit and therefore cannot mint a workspace
//  grant. It can only check the ones the app created.
//
//  Arguments are passed through in front of nothing: `serve` is prepended, never replaced, so the
//  subcommand cannot be talked into being something else — `opensheets-mcp tools` is `serve tools`
//  and exits 2, not a different program. What that pass-through is for is `--read-only`, which
//  spawns a server whose `tools/list` holds only the tools that read. Anything else after the
//  binary name is a usage error rather than an argument the server quietly ignores.

exit(await OpenSheetsCLI.run(arguments: ["serve"] + Swift.CommandLine.arguments.dropFirst()))
