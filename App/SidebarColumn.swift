import AppKit
import DocumentCore
import GlassUI
import GridKit
import SheetModel
import SwiftUI

/// The sidebar, as a **sibling in the layout** rather than a panel on top of one.
///
/// It sits below the full-width toolbar and beside the grid, so it cannot clip the toolbar's
/// leading controls and the column-header strip cannot run behind it — the two things A5's
/// component composite does, and the two things PLAN.md §3 exists to prevent.
///
/// Its width is A5's own 248 pt. There is deliberately no draggable divider: the sidebar's
/// contents are laid out for that width (the file table's label column, the feed's timestamp
/// gutter), and a divider the user can drag to 90 pt is a divider that produces a broken-looking
/// sidebar on the way to no benefit.
struct SidebarColumn: View {
    @Bindable var model: DocumentModel
    let app: AppModel
    let context: AppearanceContext
    /// The height of the anchored band that floats over this column's top. Measured by
    /// ``DocumentWindow``; the material runs up behind it, the content starts below it.
    var topInset: CGFloat = 0

    var body: some View {
        Sidebar(state: state, context: context, topInset: topInset) { action in
            perform(action)
        }
        .accessibilityLabel("Document sidebar")
    }

    private var state: SidebarState {
        SidebarState(
            sheets: model.sheetTabItems,
            selection: model.activeSheetID,
            definedNames: model.definedNameItems,
            fileInfo: fileInfo,
            claude: claude
        )
    }

    private var fileInfo: FileInfo {
        let attributes = try? FileManager.default.attributesOfItem(atPath: model.url.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return FileInfo(
            name: model.url.lastPathComponent,
            path: model.url.path(percentEncoded: false),
            folder: folderLabel,
            size: size.formatted(.byteCount(style: .file)),
            modified: formatter.string(from: modified),
            format: formatLabel,
            sheetCount: model.workbook.sheets.count,
            isReadOnly: model.workbook.meta.readOnlyReason != nil,
            containsMacros: model.workbook.meta.containsMacros
        )
    }

    /// The containing folder, with the home directory written as `~`.
    ///
    /// `abbreviatingWithTildeInPath` rather than the raw path: `/Users/quino` is the least
    /// interesting sixteen characters on screen, and spending them pushes the folder that
    /// actually distinguishes two same-named files out of the truncation. It is also the spelling
    /// the user would type. The untruncated path is still on the row's tooltip.
    private var folderLabel: String {
        (model.url.deletingLastPathComponent().path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
    }

    private var formatLabel: String {
        switch model.workbook.meta.sourceFormat {
        case .xlsx: "Excel Workbook (.xlsx)"
        case .xlsm: "Excel Macro-Enabled Workbook (.xlsm)"
        case .xltx: "Excel Template (.xltx)"
        case .csv: "Comma-separated values (.csv)"
        case .tsv: "Tab-separated values (.tsv)"
        case .new: "New workbook"
        }
    }

    private var claude: ClaudePanelState {
        ClaudePanelState(
            workspacePath: model.workspaceURL.path(percentEncoded: false),
            isGranted: app.store.grants.isAllowed(model.url),
            mcpStatus: app.mcpStatus,
            feed: model.feed,
            isWatching: model.isWatching
        )
    }

    private func perform(_ action: SidebarAction) {
        switch action {
        case let .selectSheet(id):
            model.activeSheetID = id
        case let .selectDefinedName(name):
            guard let defined = model.workbook.definedName(name) ?? model.workbook.definedNames[name],
                  let target = defined.target
            else { return }
            if let sheet = target.sheet { model.activeSheetID = sheet }
            model.selection.select(target.range, active: target.range.start)
            model.grid.scroll(to: target.range.start)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([model.url])
        case .openTerminal:
            TerminalLauncher.open(at: model.workspaceURL)
        case .grantWorkspace:
            app.grantWorkspace(model.workspaceURL)
        case .revokeWorkspace:
            if let grant = app.grants.first(where: { $0.path == model.workspaceURL.path(percentEncoded: false) }) {
                app.revokeGrant(grant)
            }
        case .copyMCPSetupCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppModel.mcpSetupCommand, forType: .string)
        case let .showFeedEntry(id):
            guard let entry = model.feed.first(where: { $0.id == id }),
                  let name = entry.sheetName,
                  let sheet = model.workbook.sheets.first(where: { $0.name == name })
            else { return }
            model.activeSheetID = sheet.id
        case .toggleWatching:
            Task { await model.setAutoRefresh(!model.isWatching) }
        }
    }
}

/// The inspector, anchored on the trailing edge. ⌘⌥1.
struct InspectorColumn: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext
    /// The anchored band's measured height — see ``SidebarColumn/topInset``.
    var topInset: CGFloat = 0

    var body: some View {
        Inspector(state: state, context: context, topInset: topInset) { action in
            perform(action)
        }
    }

    private var state: InspectorState {
        let sheet = model.activeSheet
        let styleID = sheet?.cells[model.selection.active]?.styleID
            ?? sheet?.effectiveStyleID(at: model.selection.active)
            ?? .default
        let style = model.workbook.styles[styleID]
        return InspectorState(
            selectionLabel: SelectionStatistics.label(for: model.selection),
            numberFormat: model.toolbar.numberFormat,
            customFormatCode: model.workbook.styles.numberFormat(for: styleID).formatCode,
            fontName: style.font.name,
            fontSize: style.font.size,
            isBold: style.font.isBold,
            isItalic: style.font.isItalic,
            isUnderline: style.font.underline != .none,
            borders: [],
            alignment: model.toolbar.alignment,
            verticalAlignment: vertical(style.alignment.vertical),
            wrapsText: style.alignment.wrapText,
            isEditable: model.isEditable
        )
    }

    private func vertical(_ value: CellAlignment.Vertical) -> CellVerticalAlign {
        switch value {
        case .top: .top
        case .center: .middle
        case .bottom, .justify, .distributed: .bottom
        }
    }

    private func perform(_ action: InspectorAction) {
        switch action {
        case let .setNumberFormat(choice):
            model.restyle("Number format") { $0.numberFormatID = Self.formatID(choice) }
        case let .setFontName(name):
            model.restyle("Font") { $0.font.name = name }
        case let .setFontSize(size):
            model.restyle("Font size") { $0.font.size = size }
        case .toggleBold:
            model.restyle("Bold") { $0.font.isBold.toggle() }
        case .toggleItalic:
            model.restyle("Italic") { $0.font.isItalic.toggle() }
        case .toggleUnderline:
            model.restyle("Underline") { $0.font.underline = $0.font.underline == .none ? .single : .none }
        case let .setAlignment(align):
            model.restyle("Alignment") { style in
                style.alignment.horizontal = switch align {
                case .general: .general
                case .leading: .left
                case .center: .center
                case .trailing: .right
                }
            }
        case let .setVerticalAlignment(align):
            model.restyle("Vertical alignment") { style in
                style.alignment.vertical = switch align {
                case .top: .top
                case .middle: .center
                case .bottom: .bottom
                }
            }
        case .toggleWrapText:
            model.restyle("Wrap text") { $0.alignment.wrapText.toggle() }
        default:
            break
        }
    }

    private static func formatID(_ choice: NumberFormatChoice) -> Int32 {
        switch choice {
        case .general: 0
        case .number: 4
        case .currency: 44
        case .percent: 10
        case .scientific: 11
        case .date: 14
        case .text: 49
        }
    }
}

/// The sheet tab strip, anchored along the bottom of the grid column.
///
/// # It sits on the grid, not on the window
///
/// It used to span the full window width in the outer stack, with no surface of its own — which
/// worked only while the window painted an opaque rectangle behind everything, and became a strip
/// of bare desktop the moment that went away.
///
/// It now lives inside the grid column, on the grid's own opaque plane. That is the arrangement
/// PLAN.md §3 actually asks for: the tabs are *floating glass over the one opaque plane*, which is
/// a lens with something real behind it, rather than a lens over the desktop. It also lets the
/// sidebar run unbroken to the bottom edge of the window, the way a Mac sidebar does.
struct SheetTabPlate: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext

    var body: some View {
        HStack(spacing: DS.Space.s) {
            SheetTabBar(state: state, context: context) { action in
                perform(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity)
        .gridPlane(context)
        // `.overlay`, not `.background`. Backgrounds stack backwards, so a hairline added after
        // `gridPlane` lands *behind* the opaque canvas and is never seen — which is what happened
        // when this strip gained its own plane. The same rule as the column dividers: a separator
        // is drawn on top of the surface it belongs to.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Chrome.separator(context))
                .frame(height: DS.Stroke.hairline(context))
        }
    }

    private var state: SheetTabBarState {
        SheetTabBarState(
            tabs: model.sheetTabItems,
            selection: model.activeSheetID,
            renaming: nil,
            // Addendum §4: A2's writer throws `notImplemented` for add, remove and reorder in
            // v0.1. Gating the controls here is the difference between a feature that is not
            // there yet and a save that fails after the user has done the work.
            isEditable: Flags.sheetStructureEditing && model.isEditable
        )
    }

    private func perform(_ action: SheetTabAction) {
        switch action {
        case let .select(id):
            model.activeSheetID = id
        case let .setVisibility(id, visibility):
            let resolved: SheetVisibility = switch visibility {
            case .visible: .visible
            case .hidden: .hidden
            case .veryHidden: .veryHidden
            }
            model.setSheetVisibility(id, resolved)
        default:
            break
        }
    }
}
