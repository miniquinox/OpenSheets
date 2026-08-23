import SwiftUI

/// One statistic over the selection.
///
/// Declaration order is the cycle order, and it starts with Excel's own status-bar trio.
///
/// That matters because ``SelectionStats/cycled(_:)`` slides a three-wide window along
/// `allCases`: if the default set is not a contiguous window, one click can never return to it and
/// the control stops being predictable. A test pins the round trip.
public enum SelectionStat: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case average
    case count
    case sum
    case numericCount
    case minimum
    case maximum

    public var id: String { rawValue }

    /// Excel's own vocabulary, because the people using this already know it.
    public var label: String {
        switch self {
        case .sum: "Sum"
        case .average: "Average"
        case .count: "Count"
        case .numericCount: "Numerical count"
        case .minimum: "Min"
        case .maximum: "Max"
        }
    }

    /// Average · Count · Sum — exactly what Excel's status bar shows, in Excel's order.
    ///
    /// Not an aesthetic choice. Everyone who opens this app has spent years reading those three
    /// numbers in that order in the bottom-right of a window, and moving them costs more than any
    /// improvement could return.
    public static let defaultVisible: [SelectionStat] = [.average, .count, .sum]
}

/// The numbers over the current selection.
///
/// Values arrive **pre-formatted**, like ``CellChange``'s do, for the same reason: the sum of a
/// currency column is a currency, and only the caller knows the number format. Handing this view
/// a `Double` would mean either showing `1234.5` under a column that reads `$1,234.50`, or moving
/// number formatting into the design system.
public struct SelectionStats: Sendable, Hashable {
    /// `B2:B41`, or `41R × 3C` for a multi-column selection.
    public var rangeLabel: String
    /// Formatted values, keyed by statistic. A missing key means the statistic does not apply —
    /// there is no average of a column of text, and showing `Average 0` would be a lie.
    public var values: [SelectionStat: String]
    /// Which statistics are on screen. Clicking the pill rotates this.
    public var visible: [SelectionStat]

    public init(
        rangeLabel: String,
        values: [SelectionStat: String],
        visible: [SelectionStat] = SelectionStat.defaultVisible
    ) {
        self.rangeLabel = rangeLabel
        self.values = values
        self.visible = visible
    }

    /// The statistics that both apply and are switched on.
    public var displayed: [SelectionStat] {
        visible.filter { values[$0] != nil }
    }

    /// Nothing to say. The pill hides rather than showing an empty capsule.
    public var isEmpty: Bool { displayed.isEmpty }

    /// The next rotation of the visible set: one window of three, sliding through all six.
    ///
    /// A menu would be more capable and much worse. This is a status readout in the corner of the
    /// window; the interaction budget for it is one click, and a click that always does the same
    /// small predictable thing is worth more than a click that opens a list of checkboxes.
    public static func cycled(_ visible: [SelectionStat]) -> [SelectionStat] {
        let all = SelectionStat.allCases
        guard let first = visible.first, let index = all.firstIndex(of: first) else {
            return defaultWindow(from: 0)
        }
        return defaultWindow(from: (index + 1) % all.count)
    }

    private static func defaultWindow(from start: Int) -> [SelectionStat] {
        let all = SelectionStat.allCases
        return (0 ..< 3).map { all[(start + $0) % all.count] }
    }
}

public enum SelectionStatsAction: Sendable, Hashable {
    /// The pill was clicked.
    case cycle
    /// A statistic was chosen from the context menu.
    case setVisible([SelectionStat])
    /// Copy one value to the pasteboard.
    case copy(SelectionStat)
}

/// The floating readout in the bottom-right of the grid.
///
/// Everything numeric here is tabular and the labels are fixed-width, so the pill does not change
/// size as you drag a selection across a column. A status readout that resizes while you are
/// dragging is a status readout that pulls your eye away from the thing you are dragging.
public struct SelectionStatsPill: View {
    private let stats: SelectionStats
    private let context: AppearanceContext
    private let perform: (SelectionStatsAction) -> Void

    public init(
        stats: SelectionStats,
        context: AppearanceContext,
        perform: @escaping (SelectionStatsAction) -> Void
    ) {
        self.stats = stats
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        if stats.isEmpty {
            EmptyView()
        } else {
            Button { perform(.cycle) } label: {
                HStack(spacing: DS.Space.m) {
                    Text(stats.rangeLabel)
                        .dsNumeric(DS.Text.mono)
                        .foregroundStyle(DS.Chrome.tertiary)

                    ForEach(stats.displayed) { stat in
                        HStack(spacing: DS.Space.xs) {
                            Text(stat.label)
                                .font(DS.Text.caption)
                                .foregroundStyle(DS.Chrome.secondary)
                            Text(stats.values[stat] ?? "—")
                                .dsNumeric(DS.Text.numericEmphasis)
                                .foregroundStyle(DS.Chrome.primary)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .glassPill(context: context)
            .contextMenu { menu }
            .help("Click to show different statistics")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Shows the next set of statistics")
        }
    }

    @ViewBuilder
    private var menu: some View {
        ForEach(SelectionStat.allCases) { stat in
            if let value = stats.values[stat] {
                Button("Copy \(stat.label): \(value)") { perform(.copy(stat)) }
            }
        }
        Divider()
        Button("Reset") { perform(.setVisible(SelectionStat.defaultVisible)) }
    }

    private var accessibilityLabel: String {
        let parts = stats.displayed.map { "\($0.label) \(stats.values[$0] ?? "unavailable")" }
        return ([stats.rangeLabel] + parts).joined(separator: ", ")
    }
}
