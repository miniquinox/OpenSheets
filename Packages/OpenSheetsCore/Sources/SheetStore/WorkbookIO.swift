import Foundation
import SheetModel

/// Reads a workbook from a file.
///
/// Deliberately narrow, and deliberately not `SheetFormat`'s type. `SheetStore` needs exactly
/// two verbs from the format layer, and stating them as a protocol here means this whole
/// component was built and tested against fakes while A1 and A2 were still writing the real
/// reader and writer. A8 injects the real ones; nothing here changes.
public protocol WorkbookReading: Sendable {
    /// Whether this reader handles the file at `url` — normally by extension.
    func canRead(_ url: URL) -> Bool
    /// Parses the file. Throws a `SheetError`; anything else is wrapped by the caller.
    func readWorkbook(at url: URL) throws -> Workbook
}

/// Serialises a workbook.
///
/// **The writer returns bytes; it does not write them.** That is the important part of this
/// protocol's shape. `SheetStore` owns the atomic write, the fingerprint that suppresses the
/// resulting event, and the pre-save snapshot — so a format writer *cannot* accidentally
/// bypass any of the three. A writer that took a URL would leave three separate ways to lose
/// the user's data, all of them one forgotten line away.
///
/// `originalBytes` is passed because PLAN.md §5.2's round-trip strategy re-emits only the parts
/// that changed and copies the rest through byte-identical.
public protocol WorkbookWriting: Sendable {
    /// Whether this writer can produce `url`'s format without losing what it cannot model.
    func canWrite(_ workbook: Workbook, to url: URL) -> Bool
    /// The complete file contents.
    func encodeWorkbook(_ workbook: Workbook, for url: URL, originalBytes: Data?) throws -> Data
}

/// Both halves, which is what a document session needs.
public struct WorkbookIO: Sendable {
    public var reader: any WorkbookReading
    public var writer: (any WorkbookWriting)?

    /// - Parameter writer: `nil` for a format we can read and not write. The document opens
    ///   `READ_ONLY` rather than pretending a save will work (PLAN.md §5.2).
    public init(reader: any WorkbookReading, writer: (any WorkbookWriting)? = nil) {
        self.reader = reader
        self.writer = writer
    }
}
