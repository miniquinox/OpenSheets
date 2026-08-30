import SwiftUI

/// The agent's heartbeat.
///
/// A filled accent dot with a ring that expands and fades out of it on
/// ``DS/Motion/pulsePeriod``. It appears in exactly two places — the refresh pill and the MCP
/// status row — and in both it means the same thing: *something outside this window is alive*.
///
/// Under `reduceMotion` it holds at the mid-point of the breath rather than freezing at either
/// end. Freezing at the bright end reads as an alert that will not go away; freezing at the dim
/// end reads as disconnected. Neither is what the dot means.
///
/// The ring is drawn with `.stroke` on a plain `Circle`, not with a shadow. Nothing in this
/// package casts a shadow — glass casts its own, and a second one under it doubles the penumbra.
public struct AgentDot: View {
    private let color: Color
    private let diameter: CGFloat
    private let isActive: Bool
    private let reduceMotion: Bool

    @State private var phase: Double = 0

    public init(
        color: Color,
        diameter: CGFloat = 7,
        isActive: Bool = true,
        reduceMotion: Bool = false
    ) {
        self.color = color
        self.diameter = diameter
        self.isActive = isActive
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .stroke(color, lineWidth: 1)
                    .scaleEffect(1 + phase * 1.6)
                    .opacity((1 - phase) * 0.9)
            }
            .opacity(isActive ? 1 : 0.4)
            .onAppear { startBreathing() }
            .onChange(of: isActive) { _, _ in startBreathing() }
            .onChange(of: reduceMotion) { _, _ in startBreathing() }
            .accessibilityHidden(true)
    }

    private func startBreathing() {
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) { phase = 0 }

        guard isActive, !reduceMotion else {
            if isActive { withTransaction(immediate) { phase = 0.45 } }
            return
        }
        withAnimation(.linear(duration: DS.Motion.pulsePeriod).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

/// A signal's glyph and word, together.
///
/// The word is not optional and is not only shown under increase-contrast. A signal that spells
/// itself out for some users and not others never gets designed properly — the colour-only version
/// stays ambiguous because nobody with the setting off ever sees how ambiguous it is.
public struct SignalBadge: View {
    private let kind: DS.SignalKind
    private let context: AppearanceContext
    private let showsLabel: Bool

    public init(_ kind: DS.SignalKind, context: AppearanceContext, showsLabel: Bool = true) {
        self.kind = kind
        self.context = context
        self.showsLabel = showsLabel
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
            if showsLabel {
                Text(kind.label)
                    .font(DS.Text.controlEmphasis)
            }
        }
        .foregroundStyle(kind.ink(context))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.label)
    }
}

/// A keyboard shortcut, rendered the way the menu bar renders it.
///
/// Takes the already-composed string (`"⌘R"`) rather than a `KeyboardShortcut`, because the
/// glyphs are the display concern and the actual key binding belongs to whoever owns the command
/// — which is A8, not this package.
public struct ShortcutHint: View {
    private let keys: String

    public init(_ keys: String) { self.keys = keys }

    public var body: some View {
        Text(keys)
            .font(DS.Text.mono)
            .foregroundStyle(DS.Chrome.secondary)
            .accessibilityHidden(true)
    }
}

/// A sidebar or inspector section header.
public struct SectionHeader: View {
    private let title: String
    private let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).dsSectionLabel()
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .dsNumeric(DS.Text.numericCaption)
                    .foregroundStyle(DS.Chrome.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small round glass button — the toolbar's unit of work.
///
/// Uses `.buttonStyle(.glass)` rather than a hand-rolled background, per the brief. The system
/// style already knows how to be a lens, how to merge inside a container, and how to look pressed;
/// reimplementing that is how you get a button that is *nearly* a glass button.
///
/// Each of these is one glass element, so two of them side by side need a ``GlassCluster`` around
/// them — which is what ``ToolbarGroup`` is.
///
/// It takes an ``AppearanceContext`` for one reason: **under reduce-transparency it stops being a
/// glass button.** The system style will not consult our context, and the promise the design
/// system makes is that *every* glass surface goes opaque when the user asks — not every glass
/// surface we happen to own. A toolbar of lenses floating over a solid sidebar is exactly the
/// half-honoured accessibility setting the brief calls out.
/// What a toolbar control says on hover.
///
/// One function because there are two kinds of toolbar control — a button and a button that opens
/// a menu — and they sit next to each other in the same group. Two copies of "label, then the
/// shortcut" is how one of them ends up with a different separator, or with the shortcut in
/// brackets, and a row of controls that disagree about their own tooltips reads as two toolbars.
enum ToolbarHelp {
    /// Two spaces before the shortcut, not a dash or brackets: it is what AppKit's own tooltips do
    /// and it survives being read aloud, where "Bold - command B" acquires a word nobody said.
    static func text(label: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else { return label }
        return "\(label)  \(shortcut)"
    }
}

#if canImport(AppKit)
/// Puts a real `NSView.toolTip` on the control it is attached to.
///
/// `.help(_:)` is supposed to do this and does not. Hosting a control in a real window and
/// walking its `NSView` tree finds no `toolTip` anywhere — and not only on the glass-styled
/// buttons that prompted the search: a plain `Button` with `.help` comes back empty too. So every
/// hover title in this app was silent, not merely the toolbar's. `ToolbarTooltipTests` is that
/// walk, kept, including the plain-button case as a known issue so that a future SwiftUI fixing
/// `.help` shows up as a passing test rather than as two mechanisms nobody removed.
///
/// It sets the tip on its **superview** rather than on itself. Attached as a background, this
/// view is a zero-content sibling of the label inside the control's container; the container is
/// the thing with the button's bounds and the thing the pointer is over, so it is the thing that
/// has to carry the tip. Setting it here instead would mean a tooltip on a view with no size.
/// How long the pointer has to rest before a hover title appears.
///
/// AppKit's own wait is around three seconds, which is tuned for a tooltip that explains a
/// surprise. These are not that: a toolbar of glyphs has no words on it, so the tip is the label,
/// and a label you have to wait three seconds for is a label you go and look up in a menu instead.
/// Half a second is long enough that dragging the pointer across a row does not set off nine of
/// them in a wave.
///
/// `NSInitialToolTipDelay` is an AppKit default, in milliseconds, read from the app's own domain.
/// **Registered, not written**: registration provides a fallback without touching the user's
/// stored preferences, so somebody who has deliberately set their own value keeps it.
public enum HoverTitleTiming {
    public static let defaultsKey = "NSInitialToolTipDelay"
    public static let milliseconds = 500

    /// Idempotent. `Void` in a `static let` so the work happens exactly once, on first use,
    /// whichever control gets there first.
    public static func install() { _ = installed }

    private static let installed: Void = {
        UserDefaults.standard.register(defaults: [defaultsKey: milliseconds])
    }()
}

private struct ToolTipAttachment: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> NSView { Attaching(text: text) }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? Attaching)?.apply(text)
    }

    private final class Attaching: NSView {
        private var text: String

        init(text: String) {
            self.text = text
            super.init(frame: .zero)
            // First tooltip in the process sets the delay for all of them.
            HoverTitleTiming.install()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        func apply(_ text: String) {
            self.text = text
            superview?.toolTip = text
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(text)
        }

        // Never take a click. The control underneath is the point; this only carries the tip.
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }
}
#endif

extension View {
    /// What this control says when the pointer rests on it.
    ///
    /// Use this rather than `.help(_:)` anywhere a hover title is wanted. `.help` alone sets no
    /// `NSView.toolTip` — measured, in `ToolbarTooltipTests` — so on its own it shows nothing at
    /// all. It is still applied here as well, because it is what VoiceOver reads and what a
    /// non-AppKit platform would use; the attachment is what makes the pointer show anything.
    func hoverTitle(_ text: String) -> some View {
        #if canImport(AppKit)
        // Zero-sized on purpose. The tip goes on the *superview*, so this view only has to exist
        // to find one — and a full-size background would be an extra leaf view over every control,
        // which is one more thing for anything walking the `NSView` tree to mistake for a target.
        return help(text).background(ToolTipAttachment(text: text).frame(width: 0, height: 0))
        #else
        return help(text)
        #endif
    }
}

public struct GlassIconButton: View {
    private let symbol: String
    private let label: String
    private let isOn: Bool
    private let isEnabled: Bool
    private let shortcut: String?
    /// A colour drawn as a bar under the glyph, for the controls that apply one. `nil` draws
    /// nothing at all rather than a placeholder: an empty bar under every other button in the
    /// toolbar would be six pixels of furniture describing something that is not there.
    private let bar: Color?
    private let context: AppearanceContext
    private let action: () -> Void

    public init(
        symbol: String,
        label: String,
        isOn: Bool = false,
        isEnabled: Bool = true,
        shortcut: String? = nil,
        bar: Color? = nil,
        context: AppearanceContext,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.bar = bar
        self.context = context
        self.action = action
    }

    public var body: some View {
        Group {
            if context.usesRealGlass {
                // `.glassProminent` for the on-state rather than an accent-coloured glyph.
                //
                // A glass lens takes its brightness from whatever is behind it, and the grid runs
                // underneath the toolbar by design. Over a white-filled column the lens goes light;
                // over the dark canvas it goes dark. A fixed foreground colour is legible on one of
                // those and invisible on the other — dark chrome over a white spreadsheet made half
                // the toolbar disappear, which is exactly the case PLAN.md §3.5 says to test.
                //
                // So the label colour is left to the button style, which applies the system's
                // vibrancy and adapts to the lens; and "on" is expressed by filling the lens rather
                // than by tinting the glyph.
                if isOn {
                    button.buttonStyle(.glassProminent)
                } else {
                    button.buttonStyle(.glass)
                }
            } else {
                button
                    .buttonStyle(.plain)
                    .foregroundStyle(isOn ? DS.Chrome.onAccent : DS.Chrome.primary)
                    .padding(ToolbarButtonFallback.inset)
                    .background(ToolbarButtonFallback(context: context, isOn: isOn))
            }
        }
        .disabled(!isEnabled)
        .hoverTitle(ToolbarHelp.text(label: label, shortcut: shortcut))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: Self.barGap) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                if let bar {
                    // Not `.foregroundStyle`: the bar is the document's colour, and the button
                    // style's vibrancy would tint it toward the chrome. A shape with an explicit
                    // fill is the one thing here that must survive the lens unchanged.
                    Capsule(style: .continuous)
                        .fill(bar)
                        .frame(height: Self.barHeight)
                }
            }
            // The same box whether or not there is a bar, so a row of buttons keeps one baseline.
            .frame(width: 22, height: 18)
        }
    }

    /// Thin enough to read as a swatch under a letter rather than as an underline on it.
    private static let barHeight: CGFloat = 2.5
    private static let barGap: CGFloat = 1
}

/// What a glass toolbar button becomes when transparency is reduced.
///
/// Hand-rolled rather than `.buttonStyle(.bordered)`. The system's bordered style is itself
/// translucent on macOS 26 and only goes opaque when the *real* System Settings switch is on — so
/// relying on it means the design system's promise is kept by somebody else, and cannot be seen in
/// a preview or a screenshot. This is the same opaque token plus hairline that ``GlassSurface``
/// falls back to, so a reduce-transparency toolbar matches the reduce-transparency sidebar exactly.
struct ToolbarButtonFallback: View {
    /// What `.buttonStyle(.glass)` adds around its label, measured. `.plain` adds nothing, so
    /// without this the fallback toolbar's buttons shrink to their glyphs and the groups collapse
    /// into each other — which is what the first reduce-transparency screenshot showed.
    static let inset = EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)

    let context: AppearanceContext
    var isOn: Bool = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        return shape
            .fill(isOn ? DS.Chrome.accent : DS.Surface.chrome(context))
            .overlay(
                shape.stroke(DS.Surface.border(context), lineWidth: DS.Stroke.hairline(context))
            )
    }
}

/// A label/value row, as used by the inspector and the file-info section.
///
/// The value is right-aligned with tabular figures whenever it might be a number, because a
/// column of these is read down the right edge.
public struct DetailRow: View {
    private let label: String
    private let value: String
    private let isNumeric: Bool
    private let isMonospaced: Bool

    public init(_ label: String, _ value: String, numeric: Bool = false, monospaced: Bool = false) {
        self.label = label
        self.value = value
        isNumeric = numeric
        isMonospaced = monospaced
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label)
                .font(DS.Text.control)
                .foregroundStyle(DS.Chrome.secondary)
            Spacer(minLength: DS.Space.m)
            valueText
                .foregroundStyle(DS.Chrome.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    @ViewBuilder
    private var valueText: some View {
        if isNumeric {
            Text(value).dsNumeric()
        } else if isMonospaced {
            Text(value).font(DS.Text.path)
        } else {
            Text(value).font(DS.Text.control)
        }
    }
}
