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
        .library(name: "TestSupport", targets: ["TestSupport"]),
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
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"], swiftSettings: strictSettings),
    ]
)
