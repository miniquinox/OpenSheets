import Foundation

/// How an archive entry's bytes are stored.
public enum CompressionMethod: Sendable, Hashable, Codable, RawRepresentable {
    /// Method 0 — the bytes are the bytes.
    case store
    /// Method 8 — raw DEFLATE, which is everything a real `.xlsx` uses.
    case deflate
    /// Anything else. We do not decompress these, but we can still copy them through, and
    /// keeping the number means we can say which one we refused.
    case other(UInt16)

    public init(rawValue: UInt16) {
        switch rawValue {
        case 0: self = .store
        case 8: self = .deflate
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .store: 0
        case .deflate: 8
        case let .other(value): value
        }
    }

    /// Whether we can inflate this. Reading anything else throws
    /// ``SheetError/archiveUnsupportedCompression(path:method:)``.
    public var isSupported: Bool { self == .store || self == .deflate }
}

/// The MS-DOS date and time fields a ZIP entry carries, stored raw.
///
/// Two-second resolution, no time zone, no year before 1980 — a 1980s format that every ZIP
/// still writes. Kept as the original 16-bit words rather than as a `Date` because converting
/// to a `Date` and back is lossy in both directions, and byte-identical passthrough means
/// re-emitting exactly what was there.
public struct DOSTimestamp: Sendable, Hashable, Codable {
    /// Bits 0–4 day, 5–8 month, 9–15 year minus 1980.
    public var date: UInt16
    /// Bits 0–4 seconds over two, 5–10 minute, 11–15 hour.
    public var time: UInt16

    public init(date: UInt16, time: UInt16) {
        self.date = date
        self.time = time
    }

    /// Encodes a wall-clock date. Values before 1980 clamp to 1980-01-01, which is what the
    /// format requires; seconds round down to even.
    public init(components: DateTimeComponents) {
        let year = max(0, min(127, components.year - 1980))
        date = UInt16(year << 9) | UInt16(components.month << 5) | UInt16(components.day)
        time = UInt16(components.hour << 11) | UInt16(components.minute << 5) | UInt16(components.second / 2)
    }

    /// Decodes back to wall-clock fields. Nothing validates them: a corrupt archive can encode
    /// month 15, and reporting that is more useful than pretending it said something else.
    public var components: DateTimeComponents {
        DateTimeComponents(
            year: Int(date >> 9) + 1980,
            month: Int((date >> 5) & 0x0F),
            day: Int(date & 0x1F),
            hour: Int(time >> 11),
            minute: Int((time >> 5) & 0x3F),
            second: Int(time & 0x1F) * 2
        )
    }

    /// 1980-01-01 00:00:00 — the earliest the format can express, and a reasonable stand-in
    /// when a producer left the field at zero.
    public static let epoch = DOSTimestamp(date: 0x0021, time: 0)
}

/// One entry in a ZIP archive, with everything needed to write it back out unchanged.
///
/// # Why this type is in `SheetModel`
///
/// `MiniZip` depends on `SheetModel`, not the other way round, and ``Workbook/passthrough``
/// has to hold entries. So the *data contract* lives here and `MiniZip/Types.swift` re-exports
/// it. There is no zip logic in this file — only the shape both the reader and the writer
/// agree on.
///
/// # Why it holds compressed bytes
///
/// PLAN.md §5.2's whole fidelity strategy: on read, keep every entry's **already-deflated**
/// payload; on write, copy that payload straight into the new archive for every part we did
/// not model. No re-compression means charts, pivot caches, images, and `vbaProject.bin`
/// come out bit-for-bit identical, and it is faster than re-deflating them would be.
///
/// # Why local and central extra fields are separate
///
/// They genuinely differ in real archives. Zip64 sizes and Unix timestamps are commonly
/// present in one header and absent or abbreviated in the other, and a writer that copies one
/// into both produces an archive that some tools reject. Store both, emit both.
public struct ZipEntry: Sendable, Hashable, Codable {
    /// The entry name, exactly as stored: forward slashes, no leading slash, relative.
    ///
    /// Not sanitised here. The reader validates it (``SheetError/archivePathTraversal(entryName:)``)
    /// before an entry ever reaches this type, so a `ZipEntry` in hand is already one that
    /// passed.
    public var path: String

    /// The stored bytes, still compressed by ``compressionMethod``.
    public var compressedData: Data

    /// How ``compressedData`` is encoded. Passthrough copies those bytes without caring;
    /// reading them requires ``CompressionMethod/isSupported``.
    public var compressionMethod: CompressionMethod

    /// CRC-32 of the *uncompressed* bytes, as recorded in the archive. Re-emitted verbatim on
    /// passthrough; recomputed only for entries we rewrite.
    public var crc32: UInt32

    /// Bytes in ``compressedData``, from the header. Kept separately so a mismatch with the
    /// actual payload length is detectable rather than papered over.
    public var compressedSize: UInt64

    /// Bytes the entry inflates to, from the header. **A claim, not a fact** — a zip bomb lies
    /// here, and the reader must cap what it actually inflates rather than trusting this.
    public var uncompressedSize: UInt64

    /// The MS-DOS timestamp from the header.
    public var lastModified: DOSTimestamp

    /// A higher-resolution modification time from the `0x5455` extra field, when present.
    /// Informational: the extra field itself round-trips through ``extraFieldLocal``.
    public var extendedModificationDate: Date?

    /// General-purpose bit flag. Bit 3 (data descriptor) and bit 11 (UTF-8 name) both change
    /// how an entry must be written, so this has to survive.
    public var generalPurposeFlags: UInt16

    /// Upper byte is the source filesystem, lower byte the ZIP version. Some tools care.
    public var versionMadeBy: UInt16

    /// Minimum version needed to extract.
    public var versionNeeded: UInt16

    /// Unix mode in the high 16 bits, DOS attributes in the low 16. Carries the executable bit
    /// and the directory bit.
    public var externalAttributes: UInt32

    /// Bit 0 marks an ASCII text file. Almost always zero; still round-trips.
    public var internalAttributes: UInt16

    /// The local file header's extra field, verbatim.
    public var extraFieldLocal: Data

    /// The central directory's extra field, verbatim. Often different from the local one.
    public var extraFieldCentral: Data

    /// The entry's comment, from the central directory.
    public var comment: String?

    public init(
        path: String,
        compressedData: Data,
        compressionMethod: CompressionMethod = .deflate,
        crc32: UInt32 = 0,
        compressedSize: UInt64 = 0,
        uncompressedSize: UInt64 = 0,
        lastModified: DOSTimestamp = .epoch,
        extendedModificationDate: Date? = nil,
        generalPurposeFlags: UInt16 = 0,
        versionMadeBy: UInt16 = 0x031E,
        versionNeeded: UInt16 = 20,
        externalAttributes: UInt32 = 0,
        internalAttributes: UInt16 = 0,
        extraFieldLocal: Data = Data(),
        extraFieldCentral: Data = Data(),
        comment: String? = nil
    ) {
        self.path = path
        self.compressedData = compressedData
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.compressedSize = compressedSize == 0 ? UInt64(compressedData.count) : compressedSize
        self.uncompressedSize = uncompressedSize
        self.lastModified = lastModified
        self.extendedModificationDate = extendedModificationDate
        self.generalPurposeFlags = generalPurposeFlags
        self.versionMadeBy = versionMadeBy
        self.versionNeeded = versionNeeded
        self.externalAttributes = externalAttributes
        self.internalAttributes = internalAttributes
        self.extraFieldLocal = extraFieldLocal
        self.extraFieldCentral = extraFieldCentral
        self.comment = comment
    }

    /// Whether this entry is a directory marker rather than a file.
    public var isDirectory: Bool {
        path.hasSuffix("/") || (externalAttributes & 0x0010) != 0
    }

    /// The ratio this entry *claims*. Above ``Limits/maxCompressionRatio`` is a zip bomb; real
    /// spreadsheet XML sits around 10:1.
    public var claimedCompressionRatio: Double {
        guard compressedSize > 0 else { return uncompressedSize > 0 ? .infinity : 1 }
        return Double(uncompressedSize) / Double(compressedSize)
    }
}

/// Every byte of the original archive, kept so a save can put back what it never understood.
///
/// This is the mechanism behind PLAN.md §5.2. OpenSheets models perhaps 30% of an `.xlsx` —
/// `workbook.xml`, the worksheets, `sharedStrings.xml`, `styles.xml`, the relationship parts.
/// The other 70% is charts, drawings, pivot caches, images, conditional formats, data
/// validation, comments, custom XML, and `vbaProject.bin`. A naive writer regenerates the
/// archive from its model and silently deletes all of it.
///
/// So the reader keeps every entry here, and the writer re-emits each one byte-identical
/// unless the model actually changed that part. The test contract is exact: after
/// `read → write`, every entry not in ``modelled`` must compare equal byte for byte.
public struct OpaqueParts: Sendable, Hashable, Codable {
    /// Entries in the archive's original order.
    ///
    /// Order matters. Some producers are sensitive to it, and preserving it costs nothing.
    public private(set) var entries: [ZipEntry]

    /// Paths whose content is represented in the model and may therefore be regenerated.
    ///
    /// Everything **not** in this set is untouchable. The writer's rule is a one-liner: if the
    /// path is modelled and dirty, serialise it; otherwise copy ``ZipEntry/compressedData``
    /// straight through.
    public var modelled: Set<String>

    /// Index from path to position in ``entries``, so lookup is not a linear scan.
    private var index: [String: Int]

    public init(entries: [ZipEntry] = [], modelled: Set<String> = []) {
        self.entries = entries
        self.modelled = modelled
        index = [:]
        for (position, entry) in entries.enumerated() {
            index[entry.path] = position
        }
    }

    /// Nothing kept — a workbook that did not come from an archive.
    public static let empty = OpaqueParts()

    /// The entry at `path`, or `nil`.
    public subscript(path: String) -> ZipEntry? {
        guard let position = index[path] else { return nil }
        return entries[position]
    }

    /// Whether the archive holds this path.
    public func contains(_ path: String) -> Bool { index[path] != nil }

    /// Every path, in archive order.
    public var paths: [String] { entries.map(\.path) }

    /// Paths that are **not** modelled — the ones that must survive a save untouched.
    public var passthroughPaths: [String] {
        entries.map(\.path).filter { !modelled.contains($0) }
    }

    /// Entry count.
    public var count: Int { entries.count }

    /// Whether there is nothing to pass through.
    public var isEmpty: Bool { entries.isEmpty }

    /// Total stored bytes, which is roughly the file's size on disk.
    public var totalCompressedBytes: Int {
        entries.reduce(0) { $0 + $1.compressedData.count }
    }

    /// Replaces the entry at the same path, or appends a new one at the end.
    ///
    /// Replacing keeps the original position, which is what preserves archive order across a
    /// save of a part we did model.
    public mutating func upsert(_ entry: ZipEntry) {
        if let position = index[entry.path] {
            entries[position] = entry
        } else {
            index[entry.path] = entries.count
            entries.append(entry)
        }
    }

    /// Removes an entry and returns it.
    ///
    /// The one part this is routinely used for is `xl/calcChain.xml`, which must be dropped
    /// whenever a formula changes — Excel rebuilds it, and a stale one causes real corruption
    /// (PLAN.md §5.2).
    @discardableResult
    public mutating func remove(path: String) -> ZipEntry? {
        guard let position = index[path] else { return nil }
        let removed = entries.remove(at: position)
        index.removeValue(forKey: path)
        for key in index.keys where index[key]! > position {
            index[key]! -= 1
        }
        return removed
    }

    /// Marks a path as one the model represents.
    public mutating func markModelled(_ path: String) {
        modelled.insert(path)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case entries, modelled
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(modelled.sorted(), forKey: .modelled)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entries: try container.decodeIfPresent([ZipEntry].self, forKey: .entries) ?? [],
            modelled: Set(try container.decodeIfPresent([String].self, forKey: .modelled) ?? [])
        )
    }

    public static func == (lhs: OpaqueParts, rhs: OpaqueParts) -> Bool {
        lhs.entries == rhs.entries && lhs.modelled == rhs.modelled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entries.count)
        hasher.combine(modelled)
    }
}

/// Well-known part paths inside an `.xlsx`.
///
/// Not a substitute for reading the relationship parts — the worksheet path in particular
/// **must** be resolved through `xl/_rels/workbook.xml.rels`, because files from Numbers,
/// LibreOffice, and half the Python libraries do not follow `xl/worksheets/sheetN.xml`. These
/// constants exist for the parts whose paths really are fixed, and to stop six agents from
/// each typing `"xl/calcChain.xml"` slightly differently.
public enum OOXMLPart {
    /// The part map. Must be patched whenever the set of parts changes.
    public static let contentTypes = "[Content_Types].xml"
    /// The package-level relationships, which point at the workbook part.
    public static let rootRelationships = "_rels/.rels"
    /// Sheet names, order, visibility, defined names, `calcPr`, and the 1904 flag.
    public static let workbook = "xl/workbook.xml"
    /// Where a sheet's `r:id` resolves to a real part path. **Read this rather than assuming
    /// `xl/worksheets/sheetN.xml`** — plenty of producers do not follow that convention.
    public static let workbookRelationships = "xl/_rels/workbook.xml.rels"
    /// The interned string table. Optional — a producer may use inline strings instead.
    public static let sharedStrings = "xl/sharedStrings.xml"
    /// Fonts, fills, borders, number formats, and the `cellXfs` table ``StyleID`` indexes.
    public static let styles = "xl/styles.xml"
    /// The document theme, which ``StyleColor/theme(index:tint:)`` resolves against.
    public static let theme = "xl/theme/theme1.xml"
    /// Excel's calculation-order cache. **Delete it on any formula change** — Excel rebuilds
    /// it, and a stale one causes real corruption (PLAN.md §5.2).
    public static let calcChain = "xl/calcChain.xml"
    /// Macros. Passed through byte-identical and never executed (PLAN.md §7.3).
    public static let vbaProject = "xl/vbaProject.bin"
    /// Title, creator, and timestamps.
    public static let coreProperties = "docProps/core.xml"
    /// Producing application and version.
    public static let appProperties = "docProps/app.xml"
    /// The stream an encrypted OOXML package hides its real contents in. Its presence is the
    /// reliable way to spot a password-protected file.
    public static let encryptedPackage = "EncryptedPackage"

    /// The conventional path for the nth worksheet, 1-based. A **guess** — resolve through the
    /// relationships instead wherever the real path matters.
    public static func worksheet(_ number: Int) -> String { "xl/worksheets/sheet\(number).xml" }
}

/// The set of parts a save must regenerate.
///
/// Dirty tracking is per **part**, not per workbook: editing one cell of `sheet3` must not
/// rewrite `sheet1`, `styles.xml`, or anything else, or the passthrough guarantee is worthless.
///
/// The document model owns one of these and hands it to the writer.
public struct DirtyPartSet: Sendable, Hashable, Codable {
    /// Part paths whose XML must be regenerated.
    public private(set) var paths: Set<String>

    /// Whether any formula changed anywhere.
    ///
    /// Triggers two things that are easy to forget and expensive to get wrong: `calcChain.xml`
    /// must be **deleted** (Excel rebuilds it; a stale one corrupts the file), and
    /// `calcPr/@fullCalcOnLoad` must be set so Excel recomputes what we could not.
    public var formulasChanged: Bool

    /// Whether the set of parts itself changed — a sheet added, removed, or renamed. Only then
    /// do `[Content_Types].xml` and the relationship parts need rewriting.
    public var partStructureChanged: Bool

    public init(paths: Set<String> = [], formulasChanged: Bool = false, partStructureChanged: Bool = false) {
        self.paths = paths
        self.formulasChanged = formulasChanged
        self.partStructureChanged = partStructureChanged
    }

    /// Nothing to write.
    public var isEmpty: Bool { paths.isEmpty && !formulasChanged && !partStructureChanged }

    /// Whether this part must be regenerated.
    public func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Marks a part dirty.
    public mutating func mark(_ path: String) { paths.insert(path) }

    /// Marks a sheet's own part dirty, if its path is known.
    ///
    /// Does nothing for a sheet with no ``Sheet/partPath`` — a sheet created in-app that has
    /// never been written. Adding such a sheet sets ``partStructureChanged`` instead, which is
    /// what makes the writer allocate it a path.
    public mutating func mark(sheet: Sheet) {
        if let path = sheet.partPath { paths.insert(path) } else { partStructureChanged = true }
    }

    /// Marks everything, for a save-as or a first write.
    public static var everything: DirtyPartSet {
        DirtyPartSet(paths: [], formulasChanged: true, partStructureChanged: true)
    }

    /// Clears the set after a successful save.
    public mutating func removeAll() {
        paths.removeAll()
        formulasChanged = false
        partStructureChanged = false
    }
}
