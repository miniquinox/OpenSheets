import AppKit
import DocumentCore
import GlassUI
import GridKit
import SheetModel
import SwiftUI

/// The grid, and the only two things allowed to float over it.
///
/// The grid is the app's **one opaque plane** (PLAN.md §3): everything else in the window is
/// anchored chrome sitting on it. `gridPlane(_:)` paints the canvas and turns on
/// `.backgroundExtensionEffect()`, which is what gives the chrome above something real to refract
/// instead of a hard seam between glass and content.
///
/// # Anchored *and* refracting
///
/// The grid's frame runs up **under** the toolbar and the formula bar — see ``DocumentWindow`` —
/// and `chromeInset` gives that height back as scroll range through ``GridKit/GridOptions/contentInsets``.
/// So row 1 rests just below the formula bar exactly as if the chrome were opaque, and scrolling
/// slides real cells beneath the glass, which is the only thing that makes a lens look like a lens.
/// The distinction that matters, and the one A5's composite got wrong, is *permanence*: a floating
/// panel hides rows 1–5 forever, an inset hides nothing — every cell is one scroll away.
///
/// Two floating surfaces, both in the bottom corners of the grid, at opposite ends so they can
/// never merge into one lens.
///
/// They are the only things in this window that sit over a cell, and the sync surface is
/// transient — it appears when the file changed and goes away when the change is applied or
/// dismissed. The stats pill is permanent, and the bottom inset means the last row of a sheet can
/// always be scrolled clear of it rather than living underneath it.
struct GridPane: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext
    /// How much anchored chrome sits above the grid's top edge, measured rather than assumed —
    /// the toolbar's height follows the control size and the formula bar's follows the font.
    var chromeInset: CGFloat = 0

    /// Room for the floating pills at the bottom, so the last row can clear them.
    ///
    /// A constant rather than a measurement: the sync surface appears and disappears, and a scroll
    /// range that changed under the user's fingers every time a file changed on disk would be a
    /// worse bug than the one this fixes. It is the stats pill's height plus its inset, which is
    /// the surface that is always there.
    private var floatingInset: CGFloat { DS.Metrics.pillHeight + DS.Space.floatingInset }

    var body: some View {
        ZStack(alignment: .bottom) {
            GridView(
                workbook: model.workbook,
                sheetID: model.activeSheetID,
                selection: $model.selection,
                theme: GridThemeBridge.resolved(context),
                zoom: model.zoom,
                options: GridOptions(
                    showsFormulas: model.showsFormulas,
                    isEditable: model.isEditable,
                    contentInsets: GridInsets(
                        top: Double(chromeInset),
                        bottom: Double(floatingInset)
                    )
                ),
                controller: model.grid
            ) { event in
                model.handle(event)
            }
            .accessibilityLabel("Spreadsheet grid")

            floatingLayer
        }
        .gridPlane(context)
        .alert(
            "Open this link?",
            isPresented: Binding(
                get: { model.pendingHyperlink != nil },
                set: { if !$0 { model.clearPendingHyperlink() } }
            ),
            presenting: model.pendingHyperlink
        ) { pending in
            Button("Open") {
                if let url = URL(string: pending.link.target) { NSWorkspace.shared.open(url) }
                model.clearPendingHyperlink()
            }
            Button("Cancel", role: .cancel) { model.clearPendingHyperlink() }
        } message: { pending in
            // PLAN.md §7.3: the full resolved target, before anything goes anywhere. A cell is
            // untrusted input, and a link whose text says one thing and whose target says another
            // is the oldest trick there is.
            Text(pending.link.target)
        }
    }

    // MARK: - The floating layer

    /// The two floating surfaces, at opposite corners.
    ///
    /// Deliberately **not** in one `GlassCluster`: they are different kinds of statement — one is
    /// a passive readout, one is the app asking for a decision — and merging them into a single
    /// lens would say they are the same thing. A5 annotates the same separation in its composite.
    private var floatingLayer: some View {
        // glass-lint: separated — the stats pill and the sync surface sit at opposite corners of
        // the grid and must never merge into one lens.
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            SelectionStatsPill(stats: model.selectionStats, context: context) { action in
                switch action {
                case .cycle: model.cycleSelectionStats()
                case let .setVisible(stats): model.setSelectionStats(stats)
                case let .copy(stat):
                    if let value = model.selectionStats.values[stat] {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                }
            }

            Spacer(minLength: 0)

            if let changeSet = model.changeSet {
                SyncSurface(
                    phase: model.syncPhase,
                    changeSet: changeSet,
                    filteredSheet: model.diffSheetFilter,
                    context: context
                ) { action in
                    Task { await model.handle(action) }
                }
            }
        }
        .padding(DS.Space.floatingInset)
        .animation(DS.Motion.morph(context), value: model.syncPhase)
    }
}
