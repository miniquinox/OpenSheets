//
//  XLSXWriter.swift
//  SheetFormat
//
//  The surgical writer. PLAN.md §5.2.
//

import Foundation
import MiniZip
import SheetModel

/// Writes a `Workbook` back to `.xlsx`, re-emitting only the parts that actually changed.
///
/// # The algorithm
///
/// ```text
/// for each entry in the original archive, in the original order:
///     if the part is dirty                    -> serialise it from the model
///     else if it is calcChain and a formula changed -> drop it
///     else                                    -> copy its already-deflated bytes verbatim
/// ```
///
/// That last line is the whole fidelity strategy. Charts, pivot caches, embedded images,
/// `vbaProject.bin`, custom XML, the parts nobody has thought of yet — none of them is
/// decompressed, re-parsed, or re-compressed. Their bytes are moved from one archive into
/// another, and their CRCs come along unchanged, so "byte-identical" is true by construction
/// rather than by careful re-serialisation.
///
/// # What it refuses to do
///
/// - Write a workbook whose ``WorkbookMeta/readOnlyReason`` is set. Refusing to save is always
///   better than corrupting (PLAN.md §5.2).
/// - Add, remove, or reorder a sheet in an existing package. That means a new part, a new
///   content-type override, and a new relationship, all consistent with each other and with
///   `workbook.xml`; a partial job produces a file Excel calls damaged, and v0.1 would rather
///   say so than find out in the field.
/// - Rewrite a sheet whose original part it cannot read. If the bytes we are about to replace
///   cannot be scanned for the elements we do not model, we do not know what we would be
///   deleting.
public enum XLSXWriter {
    // MARK: - Bytes

    /// The workbook as `.xlsx` bytes.
    public static func data(
        for workbook: Workbook,
        edits: WorkbookEditTracker,
        options: XLSXWriteOptions = .standard
    ) throws(SheetError) -> Data {
        if let reason = workbook.meta.readOnlyReason {
            throw SheetError.writeRefused(reason: reason)
        }
        guard !workbook.passthrough.isEmpty else {
            return try XLSXPackageBuilder.package(for: workbook, options: options)
        }
        if edits.dirty.partStructureChanged {
            throw SheetError.notImplemented(
                feature: "adding, removing or reordering a sheet in an existing workbook"
            )
        }

        var parts = workbook.passthrough

        // --- 1. the string table, loaded before any sheet needs an index --------------------
        var strings = SharedStringTable.absent
        if let entry = parts[OOXMLPart.sharedStrings] {
            strings = try SharedStringTable.parsing(try text(of: entry))
        }

        // --- 2. worksheets ------------------------------------------------------------------
        for sheet in workbook.sheets where edits.isDirty(sheet) {
            guard let path = sheet.partPath else {
                throw SheetError.notImplemented(
                    feature: "writing sheet '\(sheet.name)', which has no part in the original package"
                )
            }
            guard let entry = parts[path] else {
                throw SheetError.criticalPartMissing(path: path)
            }
            let original: String?
            do {
                original = try text(of: entry)
            } catch {
                // We are about to replace these bytes and cannot see what is in them. Anything
                // we wrote would be a guess at what we were deleting.
                throw SheetError.writeRefused(reason: .unknownCriticalPart)
            }
            let output = try WorksheetPartWriter.serialise(
                sheet,
                context: WorksheetPartWriter.Context(
                    originalXML: original,
                    strings: strings,
                    regions: edits.regions(for: sheet),
                    options: options
                )
            )
            strings = output.strings
            parts.upsert(ZipWriter.entry(path: path, contents: Data(output.xml.utf8), basedOn: entry))
        }

        // --- 3. the string table, re-emitted only if a sheet added to it ---------------------
        if let entry = parts[OOXMLPart.sharedStrings], let xml = try strings.serialised(options: options) {
            parts.upsert(ZipWriter.entry(path: OOXMLPart.sharedStrings, contents: Data(xml.utf8), basedOn: entry))
        }

        // --- 4. styles -----------------------------------------------------------------------
        if edits.dirty.contains(OOXMLPart.styles), let entry = parts[OOXMLPart.styles] {
            if let xml = try StylePartWriter.patched(try text(of: entry), table: workbook.styles) {
                parts.upsert(ZipWriter.entry(path: OOXMLPart.styles, contents: Data(xml.utf8), basedOn: entry))
            }
        }

        // --- 5. the calculation chain --------------------------------------------------------
        if edits.dirty.formulasChanged, options.dropStaleCalculationChain {
            try dropCalculationChain(from: &parts)
        }

        // --- 6. workbook.xml -----------------------------------------------------------------
        let wantsFullCalculation = (edits.dirty.formulasChanged && options.requestFullCalculationOnLoad)
            || workbook.meta.fullCalculationOnLoad
        if edits.dirty.contains(OOXMLPart.workbook) || edits.dirty.formulasChanged {
            guard let entry = parts[OOXMLPart.workbook] else {
                throw SheetError.criticalPartMissing(path: OOXMLPart.workbook)
            }
            if let xml = try WorkbookPartPatcher.patched(
                try text(of: entry),
                workbook: workbook,
                fullCalculationOnLoad: wantsFullCalculation
            ) {
                parts.upsert(ZipWriter.entry(path: OOXMLPart.workbook, contents: Data(xml.utf8), basedOn: entry))
            }
        }

        return try ZipWriter.archive(parts.entries)
    }

    // MARK: - Files

    /// Writes the workbook to `url` atomically and returns the fingerprint A6 needs to recognise
    /// the resulting filesystem event as our own.
    ///
    /// `interrupt` is a test seam; see ``AtomicFileWriter/write(_:to:interrupt:)``.
    @discardableResult
    public static func save(
        _ workbook: Workbook,
        edits: WorkbookEditTracker,
        to url: URL,
        options: XLSXWriteOptions = .standard,
        interrupt: ((AtomicFileWriter.Phase) throws -> Void)? = nil
    ) throws(SheetError) -> SavedFileFingerprint {
        let bytes = try data(for: workbook, edits: edits, options: options)
        return try AtomicFileWriter.write(bytes, to: url, interrupt: interrupt)
    }

    // MARK: - calcChain

    /// Drops `xl/calcChain.xml` and the two references to it.
    ///
    /// Excel rebuilds the chain from scratch on the next calculation, and a stale one — a
    /// dependency order that no longer describes the workbook — causes real corruption rather
    /// than a wrong number. Removing the part but leaving its `Override` in
    /// `[Content_Types].xml` and its `Relationship` in `xl/_rels/workbook.xml.rels` leaves the
    /// package pointing at something that is not there, which is invalid OPC; both go too.
    private static func dropCalculationChain(from parts: inout OpaqueParts) throws(SheetError) {
        guard parts.remove(path: OOXMLPart.calcChain) != nil else { return }

        if let entry = parts[OOXMLPart.contentTypes] {
            if let xml = try PackagePartPatcher.contentTypes(
                try text(of: entry), removingOverrideFor: OOXMLPart.calcChain
            ) {
                parts.upsert(ZipWriter.entry(path: OOXMLPart.contentTypes, contents: Data(xml.utf8), basedOn: entry))
            }
        }
        if let entry = parts[OOXMLPart.workbookRelationships] {
            if let xml = try PackagePartPatcher.relationships(
                try text(of: entry), removingTargetsFor: OOXMLPart.calcChain
            ) {
                parts.upsert(ZipWriter.entry(
                    path: OOXMLPart.workbookRelationships, contents: Data(xml.utf8), basedOn: entry
                ))
            }
        }
    }

    // MARK: - Helpers

    /// An entry's text, inflated once.
    ///
    /// Only ever called on the handful of parts a save actually rewrites. The Wave 1 addendum's
    /// rule — never inflate an entry nobody asked for — is about the *reader*; these are entries
    /// we are on our way to replacing.
    static func text(of entry: ZipEntry) throws(SheetError) -> String {
        String(decoding: try DeflateCodec.contents(of: entry), as: UTF8.self)
    }
}
