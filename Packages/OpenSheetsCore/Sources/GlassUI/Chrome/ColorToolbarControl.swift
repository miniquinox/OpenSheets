import SwiftUI

/// A toolbar control that picks a cell colour.
///
/// # Why this is a button and a popover, not a menu
///
/// Two measured reasons, both of which a `Menu` fails.
///
/// **The click target.** ``ToolbarMenuButton`` puts an invisible `Menu` over a real button to keep
/// the button's vibrancy, and `.menuStyle(.borderlessButton)` sizes its label to the label's own
/// intrinsic content. A `Rectangle` has none, so the menu laid out at 11×14 inside a 46×26 control
/// and only the middle of the glyph took a click — `.frame(maxWidth: .infinity)` on the label and
/// on the menu both failed to widen it. A plain ``GlassIconButton`` has no such problem: the whole
/// control is the target, exactly like Bold beside it.
///
/// **The colours.** `NSMenu` draws an item's image as a template — flattened to the menu's own
/// ink — so a grid of swatches rendered into a menu comes out uniformly grey, which is precisely
/// what a colour picker must not do. A popover is SwiftUI all the way down and paints what it is
/// given.
///
/// The popover also lets the swatches be a *grid*, which is what they are. Twenty-one stacked menu
/// rows named "Light purple" is a list of words about colours; five columns of colour is the
/// thing itself.
struct ColorToolbarControl: View {
    let symbol: String
    let label: String
    /// The colour currently applied, drawn under the glyph. `nil` when there is none.
    let bar: Color?
    /// "Automatic" for text, "No Fill" for a background — the two mean different things and the
    /// caller is the only one that knows which.
    let resetTitle: String
    let isEnabled: Bool
    let context: AppearanceContext
    let apply: (CellSwatches.Swatch?) -> Void

    @State private var isPresented = false

    var body: some View {
        GlassIconButton(
            symbol: symbol,
            label: label,
            isEnabled: isEnabled,
            bar: bar,
            context: context
        ) {
            isPresented = true
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button(resetTitle) {
                apply(nil)
                isPresented = false
            }
            .buttonStyle(.plain)
            .font(DS.Text.control)
            .foregroundStyle(DS.Chrome.primary)

            Divider().overlay(DS.Chrome.separator(context))

            ForEach(Array(CellSwatches.all.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DS.Space.xs) {
                    ForEach(row) { swatch in
                        chip(swatch)
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .glassAppearance(context)
    }

    private func chip(_ swatch: CellSwatches.Swatch) -> some View {
        Button {
            apply(swatch)
            isPresented = false
        } label: {
            DS.Radius.shape(DS.Radius.chip)
                .fill(swatch.display)
                .frame(width: Self.chipSide, height: Self.chipSide)
                // A hairline, not a shadow: white on a light popover and black on a dark one are
                // both invisible against their own background without one, and those two are the
                // swatches somebody reaches for most.
                .overlay {
                    DS.Radius.shape(DS.Radius.chip)
                        .strokeBorder(DS.Chrome.separator(context), lineWidth: DS.Stroke.hairline(context))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTitle(swatch.name)
        .accessibilityLabel(swatch.name)
    }

    /// Big enough to judge a colour by and to hit without aiming.
    private static let chipSide: CGFloat = 18
}
