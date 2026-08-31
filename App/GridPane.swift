import AppKit
import DocumentCore
import GlassUI
import GridKit
import SheetModel
import SwiftUI

/// The grid, and the stats pill that floats over it.
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
/// One floating surface — the stats pill, in the bottom-leading corner. (The sync surface and
/// the sheet chat are *not* here: they answer to the window's margins, not the grid's, so they
/// overlay the document area in `DocumentWindow` instead.)
///
/// The pill is the only thing here that sits over a cell, it is permanent, and the bottom inset
/// means the last row of a sheet can always be scrolled clear of it rather than living
/// underneath it.
struct GridPane: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext
    /// How much anchored chrome sits above the grid's top edge, measured rather than assumed —
    /// the toolbar's height follows the control size and the formula bar's follows the font.
    var chromeInset: CGFloat = 0

    /// Room for the stats pill at the bottom, so the last row can clear it.
    private var floatingInset: CGFloat {
        DS.Metrics.pillHeight + DS.Space.floatingInset
    }

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
                // The standing green/amber/red tints against the document's baseline. Computed
                // here rather than cached: the per-sheet change list is capped, so this walk is
                // bounded by a constant, and `baselineDiff` is observed so a new answer repaints
                // on its own. When the mapping suppresses the tints — most of the sheet changed,
                // or the differ gave up — it says so through
                // `activeChangeHighlights.isSuppressedByDensity`, which the changes panel reads.
                // The grid is never left quietly unpainted while the chip counts thousands.
                highlights: model.activeChangeHighlights.highlights,
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
                set: {
                    if !$0 {
                        model.clearPendingHyperlink()
                    }
                }
            ),
            presenting: model.pendingHyperlink
        ) { pending in
            Button("Open") {
                if let url = URL(string: pending.link.target) {
                    NSWorkspace.shared.open(url)
                }
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

    /// The stats pill, alone in its corner.
    private var floatingLayer: some View {
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
        }
        .padding(DS.Space.floatingInset)
    }
}
