import SwiftUI

/// A designed state for every way a workbook can fail to be a workbook.
///
/// PLAN.md §1.4 and §9. Every one of these is a state the app will genuinely reach — a file
/// deleted from under it, an encrypted xlsx, a network volume that unmounted — and the default
/// answer for all of them is an `NSAlert` with a `CocoaError` in it, which tells the user nothing
/// and offers them nothing.
///
/// So each state carries four things: what happened, in the user's terms; why, if the reason is
/// actionable; the one thing that would help; and a way out. The rule for the copy is that the
/// message says what to do next, never how sorry we are.
public struct EmptyStateModel: Sendable, Hashable {
    public var symbol: String
    public var title: String
    public var message: String
    /// The action most likely to help. `nil` when there genuinely isn't one.
    public var primaryLabel: String?
    public var secondaryLabel: String?
    /// Tints the glyph. `.neutral` for "nothing is here", `.failure` for "something broke".
    public var signal: DS.SignalKind
    /// The underlying error, verbatim, for the disclosure. Shown on demand rather than up front —
    /// hidden from the person who cannot use it, one click away for the person who can.
    public var technicalDetail: String?

    public init(
        symbol: String,
        title: String,
        message: String,
        primaryLabel: String? = nil,
        secondaryLabel: String? = nil,
        signal: DS.SignalKind = .neutral,
        technicalDetail: String? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.signal = signal
        self.technicalDetail = technicalDetail
    }
}

public enum EmptyStateAction: Sendable, Hashable {
    case primary
    case secondary
    case showTechnicalDetail
}

public extension EmptyStateModel {
    /// A workbook with zero sheets. Rare, legal, and a real fixture (PLAN.md §9).
    static let noSheets = EmptyStateModel(
        symbol: "rectangle.on.rectangle.slash",
        title: "This workbook has no sheets",
        message: "It opened correctly — there is simply nothing in it yet.",
        primaryLabel: "Add a sheet"
    )

    /// We parsed it and could not make sense of it.
    static func unreadable(detail: String? = nil) -> EmptyStateModel {
        EmptyStateModel(
            symbol: "doc.questionmark",
            title: "This file can't be read",
            message: "The structure doesn't match the .xlsx format. It may be damaged, or it may "
                + "be a different kind of file with a spreadsheet extension.",
            primaryLabel: "Show in Finder",
            secondaryLabel: "Open another file",
            signal: .failure,
            technicalDetail: detail
        )
    }

    /// Encrypted. We open it read-only or not at all; we never guess at a password.
    static let passwordProtected = EmptyStateModel(
        symbol: "lock.doc",
        title: "This workbook is password-protected",
        message: "OpenSheets can't decrypt it. Open it in Excel, remove the password, and save a "
            + "copy.",
        primaryLabel: "Show in Finder",
        secondaryLabel: "Open another file"
    )

    /// Deleted or moved while open. The in-memory workbook is still intact, which is the whole
    /// point of offering Save As here.
    static func fileMissing(name: String) -> EmptyStateModel {
        EmptyStateModel(
            symbol: "questionmark.folder",
            title: "\(name) is no longer where it was",
            message: "It was moved, renamed, or deleted. This window still holds the last version "
                + "it read, so you can write it somewhere else.",
            primaryLabel: "Save As…",
            secondaryLabel: "Close",
            signal: .failure
        )
    }

    /// Another process has it. Excel does this constantly.
    static func fileLocked(holder: String?) -> EmptyStateModel {
        EmptyStateModel(
            symbol: "lock.doc",
            title: "Another app has this file open",
            message: holder.map { "\($0) is holding a lock on it. Close it there and try again." }
                ?? "Something else is holding a lock on it. Close it there and try again.",
            primaryLabel: "Try again",
            secondaryLabel: "Open read-only"
        )
    }

    /// Opened, viewable, not writable. PLAN.md §5.2: refusing to save is always better than
    /// corrupting.
    static func readOnly(reason: String) -> EmptyStateModel {
        EmptyStateModel(
            symbol: "eye",
            title: "Open read-only",
            message: reason,
            primaryLabel: "Save a copy…"
        )
    }

    /// No file at all — an empty document window before anything is loaded.
    static let noDocument = EmptyStateModel(
        symbol: "tablecells",
        title: "No workbook open",
        message: "Open an .xlsx or .csv file, or drop one on this window.",
        primaryLabel: "Open…",
        secondaryLabel: "New sheet"
    )

    /// Every state, for the gallery and the snapshot matrix. Keeping the list here means a new
    /// state cannot be added without appearing in the tests.
    static let all: [EmptyStateModel] = [
        .noSheets,
        .unreadable(detail: "xlsx.missingPart(\"xl/workbook.xml\")"),
        .passwordProtected,
        .fileMissing(name: "budget.xlsx"),
        .fileLocked(holder: "Microsoft Excel"),
        .readOnly(reason: "The file is on a volume mounted read-only."),
        .noDocument,
    ]
}

/// The full-window presentation of an ``EmptyStateModel``.
///
/// Centred, quiet, and — deliberately — **not** on glass. An empty state fills the space where the
/// grid would be, and the grid is the opaque plane; floating a glass card in the middle of an
/// empty window would put a lens over nothing. The glyph and the words sit directly on the canvas.
public struct EmptyStateView: View {
    private let model: EmptyStateModel
    private let context: AppearanceContext
    private let perform: (EmptyStateAction) -> Void

    @State private var showsDetail = false

    public init(
        model: EmptyStateModel,
        context: AppearanceContext,
        perform: @escaping (EmptyStateAction) -> Void
    ) {
        self.model = model
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: model.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(
                    model.signal == .neutral ? DS.Chrome.tertiary : model.signal.ink(context)
                )
                .accessibilityHidden(true)

            VStack(spacing: DS.Space.s) {
                Text(model.title)
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Chrome.primary)
                    .multilineTextAlignment(.center)

                Text(model.message)
                    .font(DS.Text.body)
                    .foregroundStyle(DS.Chrome.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.primaryLabel != nil || model.secondaryLabel != nil {
                HStack(spacing: DS.Space.s) {
                    if let secondary = model.secondaryLabel {
                        Button(secondary) { perform(.secondary) }
                            .buttonStyle(.bordered)
                    }
                    if let primary = model.primaryLabel {
                        Button(primary) { perform(.primary) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .font(DS.Text.control)
            }

            if let detail = model.technicalDetail {
                DisclosureGroup(isExpanded: $showsDetail) {
                    Text(detail)
                        .font(DS.Text.mono)
                        .foregroundStyle(DS.Chrome.secondary)
                        .textSelection(.enabled)
                        .padding(.top, DS.Space.xs)
                } label: {
                    Text("Details")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.tertiary)
                }
                .frame(maxWidth: 380)
            }
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.title). \(model.message)")
    }
}
