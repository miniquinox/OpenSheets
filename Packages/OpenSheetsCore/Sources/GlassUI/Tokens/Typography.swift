import SwiftUI

public extension DS {
    /// Type roles. Three families, and each one is doing a job the others cannot.
    ///
    /// - **SF Pro Text** for chrome. It is what the rest of the OS is set in, and chrome that is
    ///   set in anything else announces itself as an app rather than as part of the machine.
    /// - **SF Mono** for formulas — the formula bar, the in-cell editor, the diff's before/after,
    ///   and the workspace path. Anything where a character is a *token* and the user is going to
    ///   compare it against another string character by character.
    /// - **SF Pro with tabular figures** for every number, everywhere. PLAN.md §3.4 is blunt about
    ///   this and it is right: a spreadsheet where a column of digits does not align is a broken
    ///   spreadsheet. It is not a preference and it is not only for the grid — the selection
    ///   stats pill, the diff counts and the snapshot sizes all shift under proportional figures
    ///   as they update, which reads as the UI twitching.
    ///
    /// Sizes are absolute points rather than `.body`/`.caption`, because chrome density here is
    /// closer to Xcode's than to a document app's and Dynamic Type does not apply on macOS.
    /// ``Text/scaled(_:)`` exists for the launcher, which does want to breathe.
    enum Text {
        // MARK: Chrome

        /// Window title, launcher headings.
        public static let title = Font.system(size: 15, weight: .semibold)

        /// Panel titles: "Changes on disk", "Restore points".
        public static let panelTitle = Font.system(size: 13, weight: .semibold)

        /// Default chrome text: sidebar rows, menu items, field contents.
        public static let body = Font.system(size: 13)

        /// Emphasis inside body text — a sheet name in a sentence, the primary button.
        public static let bodyEmphasis = Font.system(size: 13, weight: .semibold)

        /// Toolbar labels, tab names, inspector field labels.
        public static let control = Font.system(size: 12)
        public static let controlEmphasis = Font.system(size: 12, weight: .semibold)

        /// Units, timestamps, hints.
        public static let caption = Font.system(size: 11)

        /// Uppercase section headers in the sidebar and inspector. Tracked, because uppercase at
        /// 11pt without tracking sets too tight to scan. Apply ``sectionTracking`` with it.
        public static let sectionLabel = Font.system(size: 11, weight: .semibold)
        public static let sectionTracking: CGFloat = 0.6

        // MARK: Numbers — tabular, always

        /// Any number in chrome: stat pill values, diff counts, row/column indices.
        public static let numeric = Font.system(size: 12).monospacedDigit()

        /// A number that is the point of its row — the stats pill's active statistic.
        public static let numericEmphasis = Font.system(size: 13, weight: .semibold).monospacedDigit()

        /// Small counts on chips and badges.
        public static let numericCaption = Font.system(size: 11).monospacedDigit()

        // MARK: Formulas

        /// PLAN.md §3.4: SF Mono 12, token-coloured. The formula bar and the in-cell editor are
        /// the same face at the same size on purpose — the text does not reflow when editing
        /// moves between them.
        public static let formula = Font.system(size: 12, design: .monospaced)

        /// Before/after values in the diff, and cell references in the change feed. One point
        /// smaller than the formula face so a dense list of them stays quiet.
        public static let mono = Font.system(size: 11, design: .monospaced)

        /// File and workspace paths.
        public static let path = Font.system(size: 11, design: .monospaced)

        // MARK: Grid

        /// The face `GridKit` draws cells in, as a name and size rather than a `Font`, because
        /// Core Text needs a `CTFont`. Carried on ``GridTheme``.
        public static let cellFontSize: CGFloat = 12

        /// PLAN.md §3.4: 24pt at 100% zoom. Excel's 15pt is cramped on Retina, and 24 is also
        /// exactly two 12pt lines, which makes wrapped text land on the gridline.
        public static let defaultRowHeight: CGFloat = 24

        /// Excel's default column is 8.43 characters ≈ 64px at 96dpi. At 72pt/inch on a Mac that
        /// is meaninglessly narrow, so we widen to fit `-1,234,567.89` — the number people
        /// actually complain about seeing as `#######`.
        public static let defaultColumnWidth: CGFloat = 92
    }
}

public extension View {
    /// An uppercase, tracked section label. `SectionLabel` in the house design system.
    func dsSectionLabel() -> some View {
        font(DS.Text.sectionLabel)
            .tracking(DS.Text.sectionTracking)
            .textCase(.uppercase)
            .foregroundStyle(DS.Chrome.secondary)
    }

    /// Marks a view as numeric: tabular figures, and a right alignment that keeps the decimal
    /// point in the same place as the value changes.
    ///
    /// `.monospacedDigit()` is applied here rather than being left to the call site because the
    /// failure mode is invisible until a number changes width, at which point the layout jumps
    /// and nobody can tell you why.
    func dsNumeric(_ font: Font = DS.Text.numeric) -> some View {
        self.font(font)
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}
