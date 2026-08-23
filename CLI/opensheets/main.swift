import Foundation
import SheetMCP

//  opensheets — the human-facing command line.
//
//  Deliberately three lines. Everything the tool does lives in `SheetMCP.OpenSheetsCLI`, inside
//  the package, so it is covered by `swift test` — an executable target's `main.swift` cannot be
//  imported by a test target, and logic that lives here is logic nothing can test.
//
//  This binary does not link AppKit, and so cannot construct a `UserGrantAuthorization`. That is
//  the compile-time half of the rule that only the app can grant a folder (PLAN.md §7.2).

let arguments = Array(CommandLine.arguments.dropFirst())
exit(await OpenSheetsCLI.run(arguments: arguments))
