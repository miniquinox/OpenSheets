import Foundation
import SheetModel

/// The `_xlfn.` prefix, in both directions.
///
/// OOXML stores functions that post-date Excel 2007 with an `_xlfn.` prefix so older Excels
/// show `#NAME?` instead of a wrong answer. The user types `XLOOKUP`; the file says
/// `_xlfn.XLOOKUP`; write a bare `XLOOKUP` into a file and Excel shows `#NAME?` (see
/// WAVE-1-ADDENDUM §3). Both directions therefore have to be exact, and both are data here
/// rather than string surgery at the call sites.
public enum FunctionNames {
    /// The extra namespace prefixes Excel puts in front of a stored name. `_xlws.` marks a
    /// worksheet-only function and stacks on top of `_xlfn.`, as in `_xlfn._xlws.FILTER`.
    static let storagePrefixes = ["_XLFN.", "_XLWS."]

    /// Splits a name as written into the display name and whether it was prefixed.
    public static func normalize(_ raw: String) -> (name: String, wasPrefixed: Bool) {
        var upper = raw.uppercased()
        var prefixed = false
        var changed = true
        while changed {
            changed = false
            for prefix in storagePrefixes where upper.hasPrefix(prefix) {
                upper.removeFirst(prefix.count)
                prefixed = true
                changed = true
            }
        }
        return (upper, prefixed)
    }

    /// The name to write into `xl/worksheets/sheetN.xml` for a display name.
    ///
    /// Adds the prefix for every function that needs one whether or not the source text had
    /// it, because a user who typed `XLOOKUP` in the formula bar still needs the file to say
    /// `_xlfn.XLOOKUP`.
    public static func storedName(forDisplay name: String) -> String {
        let upper = normalize(name).name
        return FunctionCatalog.requiresStoragePrefix(upper) ? "_xlfn." + upper : upper
    }

    /// The name to show in the formula bar for a name read out of a file.
    public static func displayName(forStored name: String) -> String {
        normalize(name).name
    }

    /// Every display name that must be written with the `_xlfn.` prefix.
    public static var prefixedFunctions: [String] {
        FunctionCatalog.all.values.filter(\.requiresStoragePrefix).map(\.name).sorted()
    }
}

/// How the evaluator calls a function.
enum FunctionBody {
    /// Arguments are evaluated first, left to right.
    case eager(@Sendable (FunctionCallSite) throws -> FormulaValue)
    /// The evaluator drives argument evaluation itself, because the function decides which
    /// arguments to look at — `IF` must not evaluate the branch it does not take, and
    /// `IFERROR(1/0,"safe")` must not fail on its own first argument.
    case lazy
}

/// One function's contract.
struct FunctionSignature: Sendable {
    /// Display name, uppercased, no `_xlfn.`.
    let name: String
    /// Fewest arguments Excel accepts.
    let minimumArguments: Int
    /// Most arguments Excel accepts; `Int.max` for the variadic ones.
    let maximumArguments: Int
    /// Recomputed on every pass regardless of whether its inputs changed.
    let isVolatile: Bool
    /// Must be written to xlsx with the `_xlfn.` prefix.
    let requiresStoragePrefix: Bool
    /// When false the function sees error arguments instead of returning the first one —
    /// `ISERROR`, `IFERROR`, `ERROR.TYPE`, `N`, `TYPE`.
    let propagatesErrors: Bool
    let body: FunctionBody

    init(
        _ name: String,
        _ minimumArguments: Int,
        _ maximumArguments: Int,
        volatile: Bool = false,
        prefixed: Bool = false,
        propagatesErrors: Bool = true,
        _ body: @escaping @Sendable (FunctionCallSite) throws -> FormulaValue
    ) {
        self.name = name
        self.minimumArguments = minimumArguments
        self.maximumArguments = maximumArguments
        isVolatile = volatile
        requiresStoragePrefix = prefixed
        self.propagatesErrors = propagatesErrors
        self.body = .eager(body)
    }

    /// A function the evaluator drives itself.
    init(lazy name: String, _ minimumArguments: Int, _ maximumArguments: Int, prefixed: Bool = false) {
        self.name = name
        self.minimumArguments = minimumArguments
        self.maximumArguments = maximumArguments
        isVolatile = false
        requiresStoragePrefix = prefixed
        propagatesErrors = false
        body = .lazy
    }

    /// Whether `count` arguments is a legal call.
    func accepts(argumentCount count: Int) -> Bool {
        count >= minimumArguments && count <= maximumArguments
    }
}

/// Every function OpenSheets evaluates, and every function it knowingly does not.
///
/// The second list is as important as the first. A name we have never heard of is a typo and
/// deserves `#NAME?`; a name that is a real Excel function we chose not to implement deserves
/// the cached value and a dotted underline, because the workbook is fine and we are the ones
/// who are incomplete. Collapsing the two would either invent `#NAME?` errors in valid files
/// or hide genuine typos.
public enum FunctionCatalog {
    /// Display name → contract.
    static let all: [String: FunctionSignature] = {
        var table: [String: FunctionSignature] = [:]
        for signature in MathFunctions.signatures
            + LogicalFunctions.signatures
            + InformationFunctions.signatures
            + TextFunctions.signatures
            + DateFunctions.signatures
            + StatisticsFunctions.signatures
            + LookupFunctions.signatures
            + ConditionalFunctions.signatures {
            table[signature.name] = signature
        }
        return table
    }()

    /// Names the evaluator drives itself rather than calling with evaluated arguments.
    static let lazyFunctions: Set<String> = ["IF", "IFERROR", "IFNA", "IFS", "SWITCH", "CHOOSE"]

    /// Every implemented function, sorted. Public so the MCP surface and the docs can list
    /// exactly what we do.
    public static var implementedFunctions: [String] { all.keys.sorted() }

    /// How many functions we implement.
    public static var implementedCount: Int { all.count }

    /// Real Excel functions we deliberately do not evaluate (PLAN.md §5.3 excludes dynamic
    /// arrays, `LAMBDA`, `LET`, the financial suite, and the database functions).
    ///
    /// A formula using one of these parses, round-trips, keeps its cached value, and is
    /// flagged ``CellFlags/unsupportedFormula``.
    public static let knownUnimplemented: Set<String> = [
        // Dynamic arrays — they spill, and we do not.
        "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "TOCOL", "TOROW",
        "VSTACK", "HSTACK", "WRAPROWS", "WRAPCOLS", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS",
        "EXPAND", "GROUPBY", "PIVOTBY", "TEXTSPLIT", "TEXTBEFORE", "TEXTAFTER", "ARRAYTOTEXT",
        "TRANSPOSE", "MMULT", "MINVERSE", "MDETERM", "FREQUENCY",
        // LAMBDA and its helpers.
        "LAMBDA", "LET", "MAP", "REDUCE", "SCAN", "BYROW", "BYCOL", "MAKEARRAY", "ISOMITTED",
        // Financial.
        "PMT", "PV", "FV", "RATE", "NPER", "IPMT", "PPMT", "NPV", "IRR", "XIRR", "XNPV",
        "MIRR", "SLN", "SYD", "DB", "DDB", "VDB", "CUMIPMT", "CUMPRINC", "ACCRINT", "PRICE",
        "YIELD", "DURATION", "DOLLARDE", "DOLLARFR", "EFFECT", "NOMINAL", "ISPMT",
        // Database.
        "DAVERAGE", "DCOUNT", "DCOUNTA", "DGET", "DMAX", "DMIN", "DPRODUCT", "DSTDEV",
        "DSTDEVP", "DSUM", "DVAR", "DVARP",
        // Regression, distributions and engineering — real, and out of scope for v0.2.
        "LINEST", "LOGEST", "TREND", "GROWTH", "FORECAST", "FORECAST.LINEAR", "FORECAST.ETS",
        "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "T.DIST", "T.INV", "T.TEST",
        "CHISQ.DIST", "CHISQ.INV", "CHISQ.TEST", "F.DIST", "F.INV", "F.TEST", "Z.TEST",
        "BINOM.DIST", "POISSON.DIST", "EXPON.DIST", "WEIBULL.DIST", "GAMMA.DIST", "BETA.DIST",
        "CONFIDENCE.NORM", "CONFIDENCE.T", "COVARIANCE.P", "COVARIANCE.S", "PEARSON",
        "PERCENTILE.EXC", "QUARTILE.EXC", "RANK.AVG", "MODE.SNGL", "MODE.MULT",
        "CONVERT", "BESSELI", "BESSELJ", "BESSELK", "BESSELY", "BIN2DEC", "BIN2HEX", "BIN2OCT",
        "DEC2BIN", "DEC2HEX", "DEC2OCT", "HEX2BIN", "HEX2DEC", "HEX2OCT", "OCT2BIN", "OCT2DEC",
        "OCT2HEX", "COMPLEX", "IMABS", "IMAGINARY", "IMREAL", "DELTA", "GESTEP", "ERF", "ERFC",
        // Web, cube and pivot — they reach outside the file.
        "WEBSERVICE", "FILTERXML", "ENCODEURL", "IMAGE", "GETPIVOTDATA", "CUBEVALUE",
        "CUBEMEMBER", "CUBESET", "CUBEKPIMEMBER", "CUBERANKEDMEMBER", "CUBESETCOUNT",
        "CUBEMEMBERPROPERTY", "RTD", "HYPERLINK", "CELL", "INFO", "PHONETIC",
        // Miscellaneous but real.
        "AGGREGATE", "SUBSTITUTE.REGEX", "REGEXEXTRACT", "REGEXREPLACE", "REGEXTEST",
        "DOLLAR", "FIXED", "BAHTTEXT", "NUMBERSTRING", "ROMAN", "ARABIC", "SUMX2MY2",
        "SUMX2PY2", "SUMXMY2", "SERIESSUM", "MULTINOMIAL", "SUBTOTAL.EXC", "STOCKHISTORY",
        "YEARFRAC", "COUPDAYBS", "DAYS360", "WORKDAY.INTL", "NETWORKDAYS.INTL", "ISOWEEKNUM",
    ]

    /// The contract for a display name, or `nil` when we do not implement it.
    static func signature(for name: String) -> FunctionSignature? {
        all[FunctionNames.normalize(name).name]
    }

    /// Whether the parser should read `name (` as a call rather than an intersection.
    ///
    /// Includes the functions we do not implement: `LAMBDA (x)` is still a call, and reading
    /// it as an intersection would produce a parse error on a valid formula.
    static func isKnownName(_ name: String) -> Bool {
        let normalized = FunctionNames.normalize(name)
        if normalized.wasPrefixed { return true }
        return all[normalized.name] != nil || knownUnimplemented.contains(normalized.name)
    }

    /// Whether this display name must carry `_xlfn.` in the file.
    static func requiresStoragePrefix(_ name: String) -> Bool {
        if let signature = all[name] { return signature.requiresStoragePrefix }
        return storagePrefixedUnimplemented.contains(name)
    }

    /// Functions we do not implement that nevertheless need the prefix when written back, so
    /// a round-trip of somebody else's `_xlfn.LAMBDA` does not corrupt their file.
    static let storagePrefixedUnimplemented: Set<String> = [
        "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "TOCOL", "TOROW",
        "VSTACK", "HSTACK", "WRAPROWS", "WRAPCOLS", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS",
        "EXPAND", "GROUPBY", "PIVOTBY", "TEXTSPLIT", "TEXTBEFORE", "TEXTAFTER", "ARRAYTOTEXT",
        "LAMBDA", "LET", "MAP", "REDUCE", "SCAN", "BYROW", "BYCOL", "MAKEARRAY", "ISOMITTED",
        "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "T.DIST", "T.INV", "T.TEST",
        "CHISQ.DIST", "CHISQ.INV", "CHISQ.TEST", "F.DIST", "F.INV", "F.TEST", "Z.TEST",
        "BINOM.DIST", "POISSON.DIST", "EXPON.DIST", "WEIBULL.DIST", "GAMMA.DIST", "BETA.DIST",
        "CONFIDENCE.NORM", "CONFIDENCE.T", "COVARIANCE.P", "COVARIANCE.S",
        "PERCENTILE.EXC", "QUARTILE.EXC", "RANK.AVG", "MODE.SNGL", "MODE.MULT",
        "FORECAST.LINEAR", "FORECAST.ETS", "ISOWEEKNUM", "WORKDAY.INTL", "NETWORKDAYS.INTL",
    ]

    /// Whether calling `name` should be reported as "we cannot compute this" rather than
    /// `#NAME?`.
    static func isKnownButUnimplemented(_ name: String, wasPrefixed: Bool) -> Bool {
        // A stored `_xlfn.` prefix is Excel's own marker for "newer than 2007", so an
        // unrecognised prefixed name is a real function we have not got to, not a typo.
        wasPrefixed || knownUnimplemented.contains(name)
    }
}
