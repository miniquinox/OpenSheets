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
    /// The workbook this column describes, or `nil` when the window has a folder open and no file
    /// in it yet. With no model the column is the file tree and nothing else.
    ///
    /// Plain `let`, not `@Bindable`: nothing here ever needed `$model`, and `@Bindable` cannot
    /// wrap an optional. Reading `model.x` in `body` still tracks — that is `@Observable`, not the
    /// property wrapper.
    let model: DocumentModel?
    let app: AppModel
    let context: AppearanceContext
    /// The height of the anchored band that floats over this column's top. Measured by
    /// ``DocumentWindow``; the material runs up behind it, the content starts below it.
    var topInset: CGFloat = 0

    /// The explorer row the user last clicked, which is not the same question as "which file is
    /// open".
    ///
    /// It starts as the open file — you should be able to see where in the tree you are the
    /// moment the sidebar appears — and moves on a click, before the document window has finished
    /// changing underneath it. Local rather than on ``DocumentCore/WorkspaceTree`` because a
    /// highlight is a fact about *this* column: the launcher's copy of the same tree has its own
    /// selection, and one process-wide "selected row" would make the two windows argue.
    @State private var explorerSelection: String?

    /// The public route to the Settings scene — the gear in the Claude panel goes where the
    /// panel's own status sentences point.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Sidebar(state: state, context: context, topInset: topInset) { action in
            perform(action)
        }
        // Hand the highlight back to whatever the window is now showing. This view keeps its
        // position — and therefore its `@State` — across a tab switch, so without this the row lit
        // in the tree would go on pointing at the file you left, which is the one thing a
        // "you are here" marker must never do.
        .onChange(of: model?.url) { explorerSelection = nil }
        .accessibilityLabel("Document sidebar")
    }

    private var state: SidebarState {
        guard let model else { return SidebarState(files: files) }
        return SidebarState(
            sheets: model.sheetTabItems,
            selection: model.activeSheetID,
            definedNames: model.definedNameItems,
            fileInfo: fileInfo(model),
            claude: claude(model),
            files: files
        )
    }

    /// The granted-folder tree, or `nil` for *no such section*.
    ///
    /// Two silences, one answer. With the flag off there is nothing to show because the feature is
    /// not on; with no granted folders there is nothing to show because there is nothing there —
    /// and here the second is not worth a header, a search field and a sentence, because this is
    /// not the window you grant a folder from. (The launcher, which is, says "No folders yet."
    /// and offers the button.) Either way the sidebar renders exactly as it did before this
    /// section existed.
    ///
    /// ``DocumentCore/AppModel`` builds the tree unconditionally, so the flag is read here rather
    /// than relied on upstream. Reading `nodes` is also what registers the Observation dependency
    /// that redraws this column when a listing lands.
    private var files: FileExplorerState? {
        // Gated on the flag alone. It used to also require a non-empty tree, which hid the section
        // in exactly the case that most needs it: no folder open, and the only way to open one is
        // the control that was being hidden.
        guard Flags.explorerEnabled else { return nil }
        return WorkspaceExplorerState.explorer(
            for: app.explorer,
            selection: explorerSelection ?? openFileNodeID,
            // The `+` in the header is how you switch folders without first closing this one. The
            // Claude panel's button below grants *this workbook's* folder, which is a different
            // question — a permission, not a workspace.
            offersAddFolder: true
        )
    }

    /// Pick a folder to work in, from the document window.
    ///
    /// **Leaves the tabs alone.** Opening a folder changes what the tree is showing and nothing
    /// else: the workbook in front stays in front, every other tab stays open, and the selection
    /// does not move. A file and a folder are two independent things this window has open, and
    /// choosing one has never been a reason to close the other.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Grant first, then pin: `pin` refuses a folder no grant covers, and refuses it silently.
        // `grantWorkspace` reloads the grants synchronously, so by the next line the tree's roots
        // already include it.
        guard app.grantWorkspace(url) else { return }
        app.explorer.pin(url)
        explorerSelection = nil
    }

    /// The open document as the tree would spell it, so the row you are looking at is the row that
    /// is lit.
    ///
    /// Symlinks resolved and the path standardised, because that is what the lister mints its node
    /// ids from — an unresolved `/tmp/…` would simply never match `/private/tmp/…` and the
    /// highlight would go quietly missing rather than loudly wrong.
    private var openFileNodeID: String? {
        model?.url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }

    private func fileInfo(_ model: DocumentModel) -> FileInfo {
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
            folder: folderLabel(model),
            size: size.formatted(.byteCount(style: .file)),
            modified: formatter.string(from: modified),
            format: formatLabel(model),
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
    private func folderLabel(_ model: DocumentModel) -> String {
        (model.url.deletingLastPathComponent().path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
    }

    private func formatLabel(_ model: DocumentModel) -> String {
        switch model.workbook.meta.sourceFormat {
        case .xlsx: "Excel Workbook (.xlsx)"
        case .xlsm: "Excel Macro-Enabled Workbook (.xlsm)"
        case .xltx: "Excel Template (.xltx)"
        case .csv: "Comma-separated values (.csv)"
        case .tsv: "Tab-separated values (.tsv)"
        case .new: "New workbook"
        }
    }

    private func claude(_ model: DocumentModel) -> ClaudePanelState {
        ClaudePanelState(
            workspacePath: model.workspaceURL.path(percentEncoded: false),
            // Through `app.isGranted`, never the store's grant set directly: `store` is
            // `@ObservationIgnored` and `WorkspaceGrants` is not `@Observable`, so asking it
            // straight registers no dependency, and "Grant this folder" stays "Grant this folder"
            // after you have pressed it. Root cause #4.
            isGranted: app.isGranted(model.url),
            mcpStatus: app.mcpStatus,
            feed: model.feed
        )
    }

    private func perform(_ action: SidebarAction) {
        // The tree is the one part of this column that works without an open workbook — it is how
        // you get one. Handled before the guard, not after it.
        if case let .explorer(explorerAction) = action {
            perform(explorerAction)
            return
        }
        guard let model else { return }
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
        case .openSettings:
            openSettings()
        case .copyMCPSetupCommand:
            NSPasteboard.general.clearContents()
            // The instance property, not the static: the static assumes `opensheets-mcp` is on
            // `$PATH`, which stopped being true when the binary moved inside the app bundle. The
            // instance resolves the absolute path the Connect button would register.
            NSPasteboard.general.setString(app.setupCommand, forType: .string)
        case let .showFeedEntry(id):
            guard let entry = model.feed.first(where: { $0.id == id }),
                  let name = entry.sheetName,
                  let sheet = model.workbook.sheets.first(where: { $0.name == name })
            else { return }
            model.activeSheetID = sheet.id
        case let .explorer(explorerAction):
            perform(explorerAction)
        }
    }

    /// The files section's actions, all of which need something `GlassUI` is not allowed to hold:
    /// the tree, the window, `NSWorkspace`, or a grant.
    private func perform(_ action: FileExplorerAction) {
        switch action {
        case let .toggle(id):
            app.explorer.toggle(id)
        case let .open(id):
            // Through ``OpenActions``, never ``DocumentCore/TabsModel`` directly. That is the one
            // funnel: it records the consent the load will be checked against, notes the recent,
            // and dedupes on the document key — so a file already open in this window activates
            // its tab instead of arriving twice. The default `.fromOutsideTheApp` is the honest
            // consent here; the click happened in our UI, but the file came off the disk.
            OpenActions.open(URL(fileURLWithPath: id))
        case let .select(id):
            explorerSelection = id
        case let .refresh(id):
            // The only correction for a tree that has gone stale. Nothing watches the filesystem
            // — 77,000 directories is not something two file descriptors each can be pointed at —
            // so this is the user telling us the disk moved.
            app.explorer.refresh(id)
        case let .revealInFinder(id):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
        case let .closeFolder(id):
            // Only the tree changes. The grant stays, the tabs stay, and reopening the folder
            // costs one trip through the picker rather than a second permission decision.
            app.explorer.unpin(id)
            if explorerSelection == id { explorerSelection = nil }
        case let .revokeFolder(id):
            // Closes it too, and then takes the permission away. Order matters only for the
            // reason the comment above gives: the tree must not be left holding a root the
            // grant no longer covers. `grant(forRootID:)`, not a `path` match — the stored
            // spelling and the canonical node id differ under a symlinked parent.
            app.explorer.unpin(id)
            guard let grant = app.grant(forRootID: id) else { return }
            app.revokeGrant(grant)
        case .addFolder:
            openFolder()
        case let .search(text):
            app.explorer.search = text
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
