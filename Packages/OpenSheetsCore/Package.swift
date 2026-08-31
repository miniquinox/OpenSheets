// swift-tools-version: 6.3
import PackageDescription

// OpenSheetsCore — where ~95% of OpenSheets lives (PLAN.md §2.1).
//
// The Xcode app target is deliberately thin. Eleven agents editing one `project.pbxproj`
// produces unmergeable garbage, and adding a file to a SwiftPM target requires editing
// nothing at all. So: every new source file goes here.
//
// The dependency graph is a strict DAG rooted at `SheetModel`, which has no dependencies
// of its own — not even Foundation beyond what value types need. That is what lets seven
// agents compile in parallel without waiting on each other.

/// Swift 6 language mode everywhere: strict concurrency is not opt-in, it is the compiler's
/// default in this mode. `StrictConcurrency` is *not* also listed as an upcoming feature —
/// in v6 mode that is redundant and the compiler says so, which would break warnings-as-errors.
///
/// Warnings-as-errors is applied in CI via `-Xswiftc -warnings-as-errors` rather than being
/// baked in here: `unsafeFlags` in a manifest makes the package unusable as a dependency,
/// and `OpenSheets.xcodeproj` depends on this package by path.
///
/// `ExistentialAny` is on because `any Error` vs `Error` is a real distinction and the
/// diagnostic tells you exactly what to type. `InternalImportsByDefault` is deliberately
/// *off*: it turns `public var bytes: Data` into a confusing "Foundation was not imported
/// publicly" error, and seven agents tripping over that buys us nothing.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "OpenSheetsCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SheetModel", targets: ["SheetModel"]),
        .library(name: "MiniZip", targets: ["MiniZip"]),
        .library(name: "SheetFormat", targets: ["SheetFormat"]),
        .library(name: "SheetFormula", targets: ["SheetFormula"]),
        .library(name: "GridKit", targets: ["GridKit"]),
        .library(name: "GlassUI", targets: ["GlassUI"]),
        .library(name: "SheetStore", targets: ["SheetStore"]),
        .library(name: "SheetMCP", targets: ["SheetMCP"]),
        .library(name: "SheetShare", targets: ["SheetShare"]),
        .library(name: "SheetChat", targets: ["SheetChat"]),
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        // A9's binaries. Build with `swift build -c release --product opensheets-mcp`; the
        // resulting path is what `claude mcp add opensheets -- …` points at (docs/mcp.md).
        .executable(name: "opensheets", targets: ["opensheets"]),
        .executable(name: "opensheets-mcp", targets: ["opensheets-mcp"]),
        // One umbrella product so the app target links a single thing (PLAN.md §2.1).
        .library(
            name: "OpenSheetsCore",
            targets: [
                "SheetModel",
                "MiniZip",
                "SheetFormat",
                "SheetFormula",
                "GridKit",
                "GlassUI",
                "SheetStore",
                "SheetMCP",
                "SheetShare",
                "SheetChat",
                "DocumentCore",
            ]
        ),
    ],
    dependencies: [
        // The only external dependency in the project. SQLite in WAL mode, because the app
        // and the `opensheets-mcp` binary are two processes hitting the same database (PLAN.md §5.5).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // MARK: - The freeze

        .target(name: "SheetModel", swiftSettings: strictSettings),

        // MARK: - Wave 1

        .target(name: "MiniZip", dependencies: ["SheetModel"], swiftSettings: strictSettings),
        .target(name: "SheetFormat", dependencies: ["SheetModel", "MiniZip"], swiftSettings: strictSettings),
        .target(name: "SheetFormula", dependencies: ["SheetModel"], swiftSettings: strictSettings),
        .target(name: "GridKit", dependencies: ["SheetModel"], swiftSettings: strictSettings),
        .target(name: "GlassUI", dependencies: ["SheetModel"], swiftSettings: strictSettings),
        .target(
            name: "SheetStore",
            dependencies: ["SheetModel", "SheetFormat", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "SheetMCP",
            dependencies: ["SheetModel", "SheetFormat", "SheetFormula", "SheetStore"],
            swiftSettings: strictSettings
        ),

        // Cloud Share's app-side half: share tokens, the relay wire contract, this Mac's device
        // identity, and (later in the wave) the socket and the subprocess bridge.
        //
        // A leaf beside `SheetMCP` rather than inside it, and that placement is the feature's
        // main structural claim. `DOCUMENTATION.md` §5.9 says the MCP server makes no network
        // requests; keeping every socket in a target `SheetMCP` cannot see keeps that sentence
        // literally true rather than merely intended. `opensheets-mcp` links `SheetMCP` and not
        // this, so the serving process still cannot reach the network no matter what the app
        // does with its stdio.
        //
        // `SheetStore` is here for the share-link table and `ULID`: the engine reads link
        // records in-process to answer "is this link still live" per request, which is the
        // authoritative half of revocation.
        .target(
            name: "SheetShare",
            dependencies: ["SheetModel", "SheetStore"],
            swiftSettings: strictSettings
        ),

        // The in-app assistant: Apple's on-device foundation model, with tools bridged to the
        // *live* document rather than to the file. It sits beside `SheetMCP` deliberately — the
        // MCP server is the surface for an agent outside the process reaching the file on disk,
        // and this is the surface for the model inside the process reaching the open workbook.
        // It borrows `SheetMCP`'s untrusted-content envelope so both agent surfaces make the
        // same promise about cell text, and `GlassUI` for the value types its transcript renders
        // into. It does not depend on `DocumentCore`: the document arrives through the
        // `ChatDocument` protocol, which is what keeps the model logic testable with a fake.
        .target(
            name: "SheetChat",
            dependencies: ["SheetModel", "SheetMCP", "GlassUI"],
            swiftSettings: strictSettings
        ),

        // MARK: - Wave 2

        // A8's document model. The one place that imports every other target at once: it is where
        // the six components are wired together, and it is the only layer allowed to know about
        // more than one of them. The `App/` target on top of this is ~10 files of SwiftUI scene.
        // `SheetMCP` is here for one type: `OpenRecalculation`, the recalculate-on-open policy
        // the window and the MCP server must agree on to the cell. It used to live here, which
        // meant Claude Code read the producer's uncomputed zeroes out of the same file the user
        // saw real numbers in. `SheetMCP` is the lowest target both front ends can see; the app
        // already links it through the `OpenSheetsCore` umbrella, so this costs nothing at build
        // time and removes a whole class of disagreement.
        //
        // `SheetShare` is here for the same kind of reason, and the justification is worth
        // stating because a new edge in this graph is not free. Cloud Share's service object is
        // `@MainActor @Observable` and owned by `AppModel` — it is app state, so it belongs on
        // the layer that owns app state, not in the leaf that owns sockets and subprocesses.
        // `DocumentCore` is the one target allowed to know about more than one component, so
        // the composition happens here and the leaf stays testable without a main actor.
        .target(
            name: "DocumentCore",
            dependencies: [
                "SheetModel", "SheetFormat", "SheetFormula", "GridKit", "GlassUI", "SheetStore", "SheetMCP",
                "SheetShare",
                "SheetChat",
            ],
            swiftSettings: strictSettings
        ),

        // A9's two executables. `opensheets` is the human command line; `opensheets-mcp` is what
        // `claude mcp add opensheets -- …` points at. Both are three-line shims over
        // `SheetMCP.OpenSheetsCLI`, so everything they do is covered by `swift test` — a test
        // target cannot import an executable target's `main.swift`.
        //
        // The sources live at `CLI/<name>/` in the repository, which is *outside* this package's
        // root, and SwiftPM refuses a `path:` that escapes the root ("target is outside the
        // package root"). `Sources/<name>` is therefore a symlink to it: the layout PLAN.md and
        // `.swiftlint.yml` describe, built by the package that owns the code they link against.
        // Neither links AppKit, which is what makes "the CLI cannot mint a grant" a fact about
        // the binary rather than a promise (PLAN.md §7.2).
        .executableTarget(name: "opensheets", dependencies: ["SheetMCP"], swiftSettings: strictSettings),
        .executableTarget(name: "opensheets-mcp", dependencies: ["SheetMCP"], swiftSettings: strictSettings),

        // A7's shared toolkit: builders, fakes, matchers. Ships in the package rather than in a
        // test target so every test target can use it without a circular dependency.
        .target(name: "TestSupport", dependencies: ["SheetModel"], swiftSettings: strictSettings),

        // MARK: - Tests

        .testTarget(name: "SheetModelTests", dependencies: ["SheetModel"], swiftSettings: strictSettings),
        .testTarget(name: "MiniZipTests", dependencies: ["MiniZip", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "SheetFormatTests",
            dependencies: ["SheetFormat", "TestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SheetFormulaTests",
            dependencies: ["SheetFormula", "TestSupport"],
            // `Resources/functions.tsv` is A3's 600-row table-test corpus. Declared so SwiftPM
            // does not warn about an unhandled file, which would break `-warnings-as-errors`.
            resources: [.copy("Resources")],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "GridKitTests", dependencies: ["GridKit", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "GlassUITests", dependencies: ["GlassUI", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "SheetStoreTests",
            dependencies: ["SheetStore", "TestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "SheetMCPTests", dependencies: ["SheetMCP", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "SheetShareTests", dependencies: ["SheetShare", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "SheetChatTests", dependencies: ["SheetChat", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "DocumentCoreTests",
            dependencies: ["DocumentCore", "MiniZip", "SheetMCP", "TestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"], swiftSettings: strictSettings),
    ]
)
