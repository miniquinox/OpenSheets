//
//  WorksheetChildOrder.swift
//  SheetFormat
//
//  `CT_Worksheet` is a sequence. Emitting its children out of order is how Excel "repairs" a
//  workbook by throwing half of it away.
//

import Foundation
import SheetModel

/// The order `CT_Worksheet`'s children must be written in.
///
/// A thin projection of `SheetFragment.worksheetChildOrder` — derived, never retyped, so the
/// writer and the reader cannot drift apart about the sequence. What this adds is the ability to
/// sort raw `XMLElementSlice` values, which the model has no reason to know about.
///
/// Why the sequence matters at all: `CT_Worksheet` is an ordered sequence, not a choice, and
/// Excel's repair for a violated sequence is to drop the offending element. `<legacyDrawing>` is
/// the pointer from a sheet to the VML positioning its comments, so mis-sorting it leaves a
/// perfectly preserved `xl/comments1.xml` that nothing points at. This file originally carried a
/// local correction for `legacyDrawing`/`legacyDrawingHF`, which the model was missing; the model
/// was fixed mid-wave and the correction is gone.
public enum WorksheetChildOrder {
    /// `CT_Worksheet`'s children in schema sequence.
    public static let canonical: [String] = SheetFragment.worksheetChildOrder

    /// Where `localName` belongs.
    ///
    /// An element the schema does not name sorts into `extLst`'s slot, matching
    /// ``SheetFragment/schemaOrder(for:)`` — the least disruptive place to put a producer
    /// extension we do not recognise.
    public static func position(of localName: String) -> Int {
        let name = localName.contains(":") ? String(localName.split(separator: ":").last ?? "") : localName
        return canonical.firstIndex(of: name) ?? (canonical.count - 1)
    }

    /// Sorts children into schema sequence, stably.
    ///
    /// Stability is load-bearing: several `<conditionalFormatting>` blocks in a row is both
    /// legal and common, and re-ordering them changes which rule wins.
    public static func sorted(_ children: [XMLElementSlice]) -> [XMLElementSlice] {
        children.enumerated()
            .sorted { (position(of: $0.element.localName), $0.offset) < (position(of: $1.element.localName), $1.offset) }
            .map(\.element)
    }

    /// The fragments the model carries, in schema sequence, with the same correction applied.
    ///
    /// Starts from `[SheetFragment].inSchemaOrder` as the Wave 1 addendum requires, then applies
    /// one further stable pass over ``canonical``. Both passes are stable and the second list is
    /// a refinement of the first, so the result is exactly what a single sort over the corrected
    /// order would give.
    public static func sorted(_ fragments: [SheetFragment]) -> [SheetFragment] {
        fragments.inSchemaOrder.enumerated()
            .sorted { (position(of: $0.element.elementName), $0.offset) < (
                position(of: $1.element.elementName),
                $1.offset
            ) }
            .map(\.element)
    }
}
