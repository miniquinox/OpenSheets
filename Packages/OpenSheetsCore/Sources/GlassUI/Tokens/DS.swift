import SwiftUI

/// Design tokens — the one place to touch the look.
///
/// House pattern, from `SignalToNoise/App/Design/DesignSystem.swift`: a bare `enum`, static
/// members, and a comment on anything whose value is a judgement call rather than a fact.
///
/// The one structural difference from the house version is that colours are **functions of an
/// ``AppearanceContext``** rather than static constants. On iOS with a single dark theme a static
/// `Color` is fine. Here there are twelve combinations of scheme, reduce-transparency and
/// increase-contrast that all have to be right, plus an AppKit renderer that cannot read the
/// SwiftUI environment. Passing the context explicitly is what makes all of that reviewable.
///
/// Two rules that the lint test enforces, so they cannot rot:
///
/// - **Colour literals live in ``Palette``.** Nowhere else.
/// - **`.glassEffect` lives in `GlassSurface.swift`.** Everywhere else goes through
///   ``SwiftUI/View/glassSurface(_:in:context:)`` and its siblings, so the reduce-transparency
///   fallback can never be forgotten in one component.
public enum DS {}

// MARK: - Spacing

public extension DS {
    /// A 4pt scale, because macOS chrome is built on 4 and everything here sits next to it.
    ///
    /// Two of these are not free choices:
    /// - ``Space/glassMerge`` is the `GlassEffectContainer` spacing. It is the distance at which
    ///   two lenses stop being two lenses. Too small and adjacent controls stay separate blurs;
    ///   too large and unrelated controls blob together. 12 is where a 28pt-tall toolbar button
    ///   and its neighbour merge cleanly.
    /// - ``Space/hitSlop`` is what keeps a 7pt colour dot clickable.
    enum Space {
        public static let hair: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32

        /// `GlassEffectContainer(spacing:)`. See above — this is a physical constant, not taste.
        public static let glassMerge: CGFloat = 12

        /// Inset of floating surfaces from the window edge.
        public static let floatingInset: CGFloat = 20

        /// Minimum touch/click target padding around small controls.
        public static let hitSlop: CGFloat = 6

        // MARK: Sub-scale

        // The three below are smaller than ``hair``, and that is deliberate rather than sloppy.
        // Every one of them is a gap *inside* one thing — between a row and the next row of the
        // same list, between a chip's text and its own edge — where the job is to stop two
        // elements touching without ever reading as a separation. The 4pt scale is for gaps
        // *between* things; using it here is what makes a sidebar list look like eight unrelated
        // buttons instead of one block.
        //
        // They are named for where they go, not for how big they are, so that the next person
        // reaches for one only when they are in that situation.

        /// Between rows of a list that has to read as a single block: sidebar sheets, the
        /// snapshot list, the named-range list.
        public static let rowGap: CGFloat = 1

        /// Vertical padding inside a chip, a sheet tab, or a sync pill — anything capsule-shaped
        /// whose height is set by its text.
        public static let chipY: CGFloat = 3

        /// Horizontal padding inside a count badge. Wider than ``chipY`` because a badge is
        /// usually one or two digits and needs the width to stay round rather than oval.
        public static let badgeX: CGFloat = 5
    }

    /// Fixed sizes that are **not** spacing and cannot come off the scale: column widths laid out
    /// for their contents, a titlebar height set by the system's traffic lights, the height of a
    /// specific surface another view has to reserve room for.
    ///
    /// These live here rather than inline for one reason: an inline `72` in a layout is
    /// indistinguishable from an eyeballed guess, and the only way to tell the two apart later is
    /// to have written down which it was.
    enum Metrics {
        /// The sidebar's width. Its contents are laid out for it — the file table's label column,
        /// the feed's timestamp gutter — which is also why there is no draggable divider.
        public static let sidebarWidth: CGFloat = 248

        /// The inspector's width. Wider than the sidebar by one step because its rows are
        /// label-plus-control rather than label-only.
        public static let inspectorWidth: CGFloat = 264

        /// The document titlebar row. Matches the height AppKit gives a unified titlebar, so the
        /// traffic lights sit on its centre line.
        public static let titleBarHeight: CGFloat = 38

        /// Clearance for the window's traffic lights, which are drawn by AppKit over our content
        /// because the titlebar is transparent and full-size.
        public static let trafficLightInset: CGFloat = 72

        /// The height of a floating pill. ``GridKit`` reserves this at the bottom of the grid so
        /// the last row can always be scrolled clear of the stats pill.
        public static let pillHeight: CGFloat = 32

        /// The smallest a document window may get. Below this the toolbar starts dropping
        /// controls and the sidebar plus the inspector leave under three columns of grid, which
        /// is a window nobody can work in.
        public static let minimumWindowWidth: CGFloat = 900
        public static let minimumWindowHeight: CGFloat = 560
    }
}

// MARK: - Shape

public extension DS {
    /// PLAN.md §3.3: `card 24 · pill capsule · control 10 · cellEditor 6`, all `.continuous`.
    ///
    /// `.continuous` everywhere is not a preference. A circular-arc corner next to a squircle
    /// reads as a rendering bug, and real Liquid Glass edges are squircles.
    enum Radius {
        /// Diff panel, command palette, inspector, launcher card.
        public static let card: CGFloat = 24
        /// Sidebar rows, popovers, menu surfaces — a card that is attached to something.
        public static let panel: CGFloat = 16
        /// Buttons, segmented controls, the name box.
        public static let control: CGFloat = 10
        /// The in-cell editor. Small, because it has to sit inside a 24pt row without
        /// visually eating the gridlines.
        public static let cellEditor: CGFloat = 6
        /// Chips and dots.
        public static let chip: CGFloat = 7

        /// No radius at all — an edge-anchored band that runs into the window's own corners.
        ///
        /// A rounded card butted against the window edge is the single clearest sign of a panel
        /// that has not decided whether it floats: it has the corners of something detached and
        /// nowhere to be detached to. A flush band is the native idiom (Finder, Mail, Xcode) and
        /// the window's own corner radius does the rounding.
        public static let flush: CGFloat = 0

        public static func shape(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }

        public static var cardShape: RoundedRectangle { shape(card) }
        public static var panelShape: RoundedRectangle { shape(panel) }
        public static var controlShape: RoundedRectangle { shape(control) }
    }
}

// MARK: - Strokes

public extension DS {
    /// Line weights. Everything here doubles as a `GridTheme` input, so it is in points and the
    /// renderer converts.
    enum Stroke {
        /// The gridline, and the hairline on a reduce-transparency surface.
        public static let hairline: CGFloat = 1

        /// PLAN.md §3.3: a 2pt accent stroke around the selection.
        public static let selection: CGFloat = 2

        /// Increase-contrast selection. Three points, because at 2pt the stroke and the gridline
        /// under it are within one point of each other and the eye has to work.
        public static let selectionContrast: CGFloat = 3

        /// Frozen-pane divider.
        public static let major: CGFloat = 1.5

        public static func selection(_ context: AppearanceContext) -> CGFloat {
            context.increaseContrast ? selectionContrast : selection
        }

        public static func hairline(_ context: AppearanceContext) -> CGFloat {
            context.increaseContrast ? 1.5 : hairline
        }
    }
}

// MARK: - Motion

public extension DS {
    /// Springs only.
    ///
    /// PLAN.md §3.3 fixes the canonical spring at `response 0.35, damping 0.85`, and
    /// ``Motion/standard`` is exactly that — including for the pill→panel morph, which is the one
    /// place the temptation to add overshoot is strongest. Liquid Glass already deforms during a
    /// morph; a springier spring on top of that reads as a bounce, and a spreadsheet that bounces
    /// is a spreadsheet nobody trusts with their numbers.
    ///
    /// **The grid scroll is never animated.** It has to be 1:1 with the trackpad. That is A4's
    /// rule, restated here because this is where somebody would go looking for a scroll spring.
    enum Motion {
        /// The app's spring. Selection, morphs, panel presentation, sheet-tab reorder.
        public static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)

        /// Press and hover feedback. Shorter response only — a 0.35s response on a hover state
        /// lags visibly behind the cursor.
        public static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)

        /// Content arriving inside a surface that has already finished moving: the diff rows
        /// after the panel opens. Slower and fully damped, so the shape leads and the content
        /// follows rather than the two racing.
        public static let settle = Animation.spring(response: 0.5, dampingFraction: 0.95)

        /// The **only** non-spring in the design system, and the lint test knows it by name.
        ///
        /// Under `accessibilityReduceMotion` the morph is replaced by a cross-fade, and a spring
        /// on an opacity is meaningless — there is nothing to overshoot. It is also short enough
        /// that a user who asked for less motion does not sit through a dissolve.
        public static let crossFade = Animation.easeInOut(duration: 0.18)

        /// Picks the morph animation for the context. Call this rather than branching at the site.
        public static func morph(_ context: AppearanceContext) -> Animation {
            context.reduceMotion ? crossFade : standard
        }

        /// PLAN.md §1.2: changed cells flash accent, then fade over six seconds.
        ///
        /// Six is long. That is the point — it has to survive the user reading the diff panel,
        /// looking away, and coming back. It is also the number A4 needs for the flash decay.
        public static let changeFlashDuration: TimeInterval = 6

        /// The agent dot's breath, in seconds per cycle. Static under reduce-motion.
        public static let pulsePeriod: TimeInterval = 1.8
    }
}

// MARK: - Chrome colours

public extension DS {
    /// Chrome uses **semantic system colours**, on purpose.
    ///
    /// The grid is ours and must be opaque (see ``Palette``). Chrome is the opposite case: it
    /// sits on real glass, and real glass has its own vibrancy, key-window dimming, and
    /// increase-contrast behaviour that the system applies to `.primary`, `.secondary` and
    /// `separatorColor` for free. Hardcoding an ink here would opt the app out of all of it and
    /// make the toolbar look subtly wrong the moment the window loses focus.
    ///
    /// So: if it is text or a separator on glass, it is one of these. If it lands on the grid
    /// plane, it is a ``Palette`` value.
    enum Chrome {
        /// Labels, values, the formula bar's text.
        public static let primary = Color.primary
        /// Captions, units, the name box's placeholder.
        public static let secondary = Color.secondary
        /// Disabled controls, the "no defined names" hint.
        public static let tertiary = Color.secondary.opacity(0.55)

        /// The user's accent. **Never hardcode blue** — this reads
        /// `NSColor.controlAccentColor` through SwiftUI, so it also picks up the system's
        /// unemphasised treatment when the window is not key.
        public static let accent = Color.accentColor

        /// `NSColor.separatorColor`. Measured: black at 9.8% light, white at 9.8% dark.
        public static let separator = Color(nsColor: .separatorColor)

        /// Row selection inside the sidebar and lists — the same colour Finder uses.
        public static let selectedRow = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

        /// Text on a filled accent surface.
        public static let onAccent = Color.white

        /// Separator, heavier under increase-contrast.
        public static func separator(_ context: AppearanceContext) -> Color {
            context.increaseContrast
                ? context.pick(
                    light: Palette.solidBorderContrastLight,
                    dark: Palette.solidBorderContrastDark
                ).color
                : separator
        }
    }
}

// MARK: - Signal colours

public extension DS {
    /// Three signals. Adding a fourth is a design change, not a code change.
    ///
    /// Each has a **tint** (what the glass is dyed with) and an **ink** (what the text and glyph
    /// use). They are separate tokens because amber-as-tint is unreadable as amber-as-text in
    /// light mode, and collapsing them into one value with an opacity is how you get a banner
    /// nobody can read.
    ///
    /// Under `increaseContrast`, or `differentiateWithoutColor`, tint alone is not allowed to
    /// carry the meaning — every signal surface also renders a glyph and a word. See
    /// ``SignalKind/symbolName``.
    enum Signal {
        /// The tint a signal dyes glass with, as a value. `nil` for ``SignalKind/neutral`` —
        /// plain glass, no tint, which is the majority of surfaces in the app.
        public static func tintValue(_ kind: SignalKind, _ context: AppearanceContext) -> RGBA? {
            switch kind {
            case .agent: context.accent
            case .conflict: context.pick(
                    light: Palette.conflictTintLight,
                    dark: Palette.conflictTintDark
                )
            case .failure: context.pick(light: Palette.errorTintLight, dark: Palette.errorTintDark)
            case .neutral: nil
            }
        }

        /// How strongly a signal dyes its lens.
        ///
        /// Not 1.0, and the number is not taste. `Glass.tint(_)` at full strength stops being
        /// glass: it renders as a saturated slab of colour with the grid faintly behind it, and
        /// the text on top of it inherits whatever contrast the user's accent happens to give —
        /// which for the macOS yellow accent is 1.4:1. At 0.42 the lens keeps the hue and keeps
        /// the refraction, and the worst case across all eight macOS accent presets, both schemes
        /// and all three signals is 4.79:1. `PaletteContrastTests` holds that line.
        ///
        /// It also fixed the design: a 380-point diff panel dyed at full strength was the loudest
        /// object in a design system whose whole premise is quiet.
        public static let glassTintStrength = 0.42

        /// What a tinted lens actually resolves to, modelled as the tint at
        /// ``glassTintStrength`` over the floating surface.
        ///
        /// A model, not a measurement — `Glass` is opaque and there is no API that resolves one to
        /// a colour. It is the same model the contrast tests use, so the ink and the assertion can
        /// never disagree with each other, only with reality.
        public static func lensValue(_ kind: SignalKind, _ context: AppearanceContext) -> RGBA? {
            guard let tint = tintValue(kind, context) else { return nil }
            return tint.opacity(glassTintStrength).composited(over: Surface.floatingColor(context))
        }

        /// The ink for text and glyphs sitting **on** a tinted signal surface.
        ///
        /// This is not ``Chrome/primary``, and the difference is a real bug we shipped into a
        /// screenshot before catching it. SwiftUI picks a vibrant label colour from the *colour
        /// scheme*: white in dark mode. But `.regular.tint(_)` takes its luminance from the
        /// *tint*, and the conflict amber is light in both schemes — so a dark-mode conflict
        /// banner rendered white text on a pale amber lens at about 2.5:1.
        ///
        /// So the choice is made against the **lens**, and it is made by measurement rather than
        /// by a luminance threshold: whichever of the two inks scores higher, wins. A threshold
        /// gets the mid-luminance accents wrong — macOS orange sits just below any sensible
        /// cut-off and would take white ink at 2.57:1 when black would have given it 8:1.
        public static func inkOnTint(_ kind: SignalKind, _ context: AppearanceContext) -> Color {
            inkValueOnTint(kind, context).color
        }

        /// The value form, for the contrast tests.
        public static func inkValueOnTint(_ kind: SignalKind, _ context: AppearanceContext) -> RGBA {
            guard let lens = lensValue(kind, context) else {
                return context.pick(light: Palette.inkLight, dark: Palette.inkDark)
            }
            let dark = Palette.onTintDark
            let light = Palette.onTintLight
            return dark.contrastRatio(against: lens) >= light.contrastRatio(against: lens)
                ? dark
                : light
        }

        /// "Claude changed this." The user's accent, so the agent's colour is the app's colour.
        public static func agentTint(_ context: AppearanceContext) -> Color { context.accent.color }
        public static func agentInk(_ context: AppearanceContext) -> Color { Chrome.accent }

        /// "You and the file disagree."
        public static func conflictTint(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.conflictTintLight, dark: Palette.conflictTintDark).color
        }

        public static func conflictInk(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.conflictInkLight, dark: Palette.conflictInkDark).color
        }

        /// "This failed."
        public static func errorTint(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.errorTintLight, dark: Palette.errorTintDark).color
        }

        public static func errorInk(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.errorInkLight, dark: Palette.errorInkDark).color
        }

        /// Nothing is happening. Watching, synced, paused, read-only.
        public static func calmInk(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.calmInkLight, dark: Palette.calmInkDark).color
        }

        /// The MCP status dot when Claude is connected. The only green in the app.
        public static func connected(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.connectedLight, dark: Palette.connectedDark).color
        }

        /// A value we could not recompute.
        public static func staleInk(_ context: AppearanceContext) -> Color {
            context.pick(light: Palette.inkStaleLight, dark: Palette.inkStaleDark).color
        }
    }

    /// What a signal surface *means*. Carries its own tint, glyph and word so that no caller has
    /// to remember that amber means conflict.
    enum SignalKind: String, Sendable, Hashable, CaseIterable, Codable {
        /// The agent, or the file, changed something. Accent.
        case agent
        /// Local edits and disk edits disagree. Amber.
        case conflict
        /// Something failed. Red.
        case failure
        /// Nothing is wrong. No tint at all — plain glass.
        case neutral

        public func tint(_ context: AppearanceContext) -> Color? {
            Signal.tintValue(self, context)?.color
        }

        public func ink(_ context: AppearanceContext) -> Color {
            switch self {
            case .agent: Signal.agentInk(context)
            case .conflict: Signal.conflictInk(context)
            case .failure: Signal.errorInk(context)
            case .neutral: Chrome.secondary
            }
        }

        /// The glyph that carries the meaning when colour cannot — under increase-contrast,
        /// differentiate-without-colour, or simply for someone who does not know the convention
        /// yet. It is always drawn, not only in the accessible variants: a signal that only
        /// appears for some users is a signal that never gets designed properly.
        public var symbolName: String {
            switch self {
            case .agent: "sparkle"
            case .conflict: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            case .neutral: "circle"
            }
        }

        /// The word. Spoken by VoiceOver, and shown next to the glyph under increase-contrast.
        public var label: String {
            switch self {
            case .agent: "Changed"
            case .conflict: "Conflict"
            case .failure: "Error"
            case .neutral: "Idle"
            }
        }
    }
}

// MARK: - Solid surfaces

public extension DS {
    /// What glass becomes when the user asks for less transparency.
    ///
    /// Opaque, with a hairline. This is the **only** place a border is allowed in the design
    /// system, and it exists precisely because there is no glass edge to muddy — see the note on
    /// ``GlassSurface``.
    /// Each surface comes in two forms: an `RGBA` (what it *is*, printable and testable) and a
    /// `Color` (what SwiftUI needs). The `Color` is always derived from the `RGBA`, never defined
    /// separately, so there is one value and one place to change it.
    enum Surface {
        public static func chromeColor(_ context: AppearanceContext) -> RGBA {
            context.pick(light: Palette.solidChromeLight, dark: Palette.solidChromeDark)
        }

        public static func floatingColor(_ context: AppearanceContext) -> RGBA {
            context.pick(light: Palette.solidFloatingLight, dark: Palette.solidFloatingDark)
        }

        public static func borderColor(_ context: AppearanceContext) -> RGBA {
            if context.increaseContrast {
                return context.pick(
                    light: Palette.solidBorderContrastLight,
                    dark: Palette.solidBorderContrastDark
                )
            }
            return context.pick(light: Palette.solidBorderLight, dark: Palette.solidBorderDark)
        }

        /// A tinted solid, for a signal surface under reduce-transparency. The tint is mixed into
        /// the solid rather than laid over it, so the result is still one opaque colour.
        public static func signalColor(_ kind: SignalKind, _ context: AppearanceContext) -> RGBA {
            let base = floatingColor(context)
            guard let tint = Signal.tintValue(kind, context) else { return base }
            return base.mixed(with: tint, amount: context.isDark ? 0.16 : 0.12)
        }

        public static func chrome(_ context: AppearanceContext) -> Color {
            chromeColor(context).color
        }

        public static func floating(_ context: AppearanceContext) -> Color {
            floatingColor(context).color
        }

        public static func border(_ context: AppearanceContext) -> Color {
            borderColor(context).color
        }

        public static func signal(_ kind: SignalKind, _ context: AppearanceContext) -> Color {
            signalColor(kind, context).color
        }
    }
}
