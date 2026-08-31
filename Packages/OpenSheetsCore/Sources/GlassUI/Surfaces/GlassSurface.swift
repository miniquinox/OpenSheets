import SwiftUI

/// The three tiers of glass, from PLAN.md §3.1.
///
/// A tier is not a look, it is a *position in space*. Chrome is anchored to an edge and the grid
/// bleeds under it. Floating is detached and can be dismissed. Signal is floating plus a meaning.
/// Getting the tier right is most of getting the surface right.
public enum GlassTier: String, Sendable, Hashable, CaseIterable, Codable {
    /// `.glassEffect(.regular, in:)` — toolbar, formula bar, sheet tabs, sidebar, inspector.
    ///
    /// Edge-anchored, never interactive as a whole (its *contents* are), and the grid runs
    /// underneath it via ``SwiftUI/View/gridPlane(_:)``.
    case chrome

    /// `.regular.interactive()` — stats pill, refresh pill, command palette, snapshot browser.
    ///
    /// `.interactive()` makes the lens respond to the pointer, which is the difference between a
    /// control and a card. Do not put it on chrome: a toolbar that flexes under the cursor is
    /// distracting when you are looking at it for eight hours.
    case floating

    /// `.regular.tint(_)` — conflict banner, error states, "Claude changed this".
    ///
    /// Tint is semantic and there are exactly three of them. See ``DS/SignalKind``.
    case signal

    /// `.regular.tint(frost).interactive()` — the sheet-chat bubble and its panel.
    ///
    /// Floating, but **frosted**, the way the system's own volume HUD is: a white frost tint
    /// lifts the lens off whatever is beneath it, so the surface reads as a control in its own
    /// right rather than as a dark window onto the grid. The plain floating tier is the right
    /// default — a lens should show the document — but a *conversation* is not a readout of the
    /// cells behind it, and rendering it as one made it look switched off. The frost is a look,
    /// not a meaning, which is why this is a tier and not a fourth ``DS/SignalKind``.
    case hud
}

/// The signature surface.
///
/// On macOS 26 this is *real* Liquid Glass: the system material that refracts what is behind it,
/// with its own edge lighting, its own specular response and its own shadow.
///
/// **Nothing is layered on top of it.** No border, no shadow, no `.ultraThinMaterial`. The system
/// has a lighting model and adding to it just muddies it — a stroked edge over a glass edge reads
/// as a seam, and a drop shadow under a surface that already casts one doubles the penumbra. This
/// exact note is in the house `DesignSystem.swift`; it is repeated here because it is the rule
/// most likely to be broken by somebody trying to make a surface "pop", and `GlassLintTests`
/// fails the build when it is.
///
/// **When `reduceTransparency` is on there is no glass at all.** The surface becomes an opaque
/// ``DS/Surface`` token with a hairline border — the one place a border is legal, precisely
/// because there is no glass edge left to interfere with. Not a heavier blur, not a darker tint:
/// opaque. The setting exists because translucency makes text hard to read, and half-honouring it
/// is worse than ignoring it.
///
/// **Clusters.** Two of these next to each other are two lenses, and stacked lenses are the single
/// clearest tell of fake glass. Any group of two or more must be wrapped in ``GlassCluster``,
/// which is `GlassEffectContainer` with the right spacing. The lint test counts them.
///
/// **No glass inside glass.** A container merges *siblings*; it does nothing for a glass button
/// sitting on a glass panel, which is simply two lenses stacked with no air between them. So:
/// `.buttonStyle(.glass)` is for controls that float directly over the grid — the toolbar. A
/// button inside the diff panel, the conflict banner, the palette or the inspector is
/// `.bordered`, `.borderedProminent` or `.plain`, because the panel is already the glass. The
/// lint test fails a view that applies a glass surface and a glass button style at once.
public struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tier: GlassTier
    let context: AppearanceContext
    /// Only meaningful for ``GlassTier/signal``. Ignored otherwise — a tinted toolbar is not a
    /// thing this app has.
    var signal: DS.SignalKind = .neutral

    public func body(content: Content) -> some View {
        let resolution = GlassResolution.resolve(tier: tier, signal: signal, context: context)
        if resolution.usesRealGlass {
            content.glassEffect(glass, in: shape)
        } else {
            content.background {
                shape
                    .fill(resolution.solidFill?.color ?? Color.clear)
                    .overlay(
                        shape.stroke(
                            resolution.borderColor?.color ?? Color.clear,
                            lineWidth: resolution.borderWidth
                        )
                    )
            }
        }
    }

    /// The one `Glass` value in the package. Built here so there is exactly one place where the
    /// tier→API mapping lives.
    private var glass: Glass {
        switch tier {
        case .chrome:
            .regular
        case .floating:
            .regular.interactive()
        case .signal:
            DS.Signal.tintValue(signal, context)
                .map { Glass.regular.tint($0.opacity(DS.Signal.glassTintStrength).color) }
                ?? .regular
        case .hud:
            .regular.tint(DS.Surface.hudFrost(context).color).interactive()
        }
    }
}

/// What ``GlassSurface`` will actually do, as a value.
///
/// The modifier reads this rather than branching inline, which turns the most important decision
/// in the design system — *is this real glass, and if not, exactly which solid* — into something a
/// test can print. `AppearanceSnapshotTests` records one of these per component per appearance, so
/// a change to the reduce-transparency path shows up in a diff as a hex value rather than as
/// "GlassSurface.swift changed".
///
/// `Glass` itself is opaque and has no accessors, so the real-glass branch is described rather than
/// captured. That is an honest limit: the snapshot proves we *asked* for `.regular.interactive()`,
/// not what the compositor did with it.
public struct GlassResolution: Sendable, Hashable, CustomStringConvertible {
    public let tier: GlassTier
    public let signal: DS.SignalKind
    public let usesRealGlass: Bool
    /// `regular`, `regular.interactive`, `regular.tint(#FFB020)`. `nil` when there is no glass.
    public let glassRecipe: String?
    /// The opaque token used when transparency is reduced.
    public let solidFill: RGBA?
    /// The hairline that replaces the glass edge — the only border in the design system.
    public let borderColor: RGBA?
    public let borderWidth: CGFloat

    public static func resolve(
        tier: GlassTier,
        signal: DS.SignalKind = .neutral,
        context: AppearanceContext
    ) -> GlassResolution {
        guard context.usesRealGlass else {
            let fill: RGBA = switch tier {
            case .chrome: DS.Surface.chromeColor(context)
            case .floating, .hud: DS.Surface.floatingColor(context)
            case .signal: DS.Surface.signalColor(signal, context)
            }
            return GlassResolution(
                tier: tier,
                signal: signal,
                usesRealGlass: false,
                glassRecipe: nil,
                solidFill: fill,
                borderColor: DS.Surface.borderColor(context),
                borderWidth: DS.Stroke.hairline(context)
            )
        }

        let recipe: String
        switch tier {
        case .chrome:
            recipe = "regular"
        case .floating:
            recipe = "regular.interactive"
        case .hud:
            recipe = "regular.tint(\(DS.Surface.hudFrost(context).hexString)).interactive"
        case .signal:
            if signal == .neutral {
                recipe = "regular"
            } else {
                let tint = DS.Signal.tintValue(signal, context)?
                    .opacity(DS.Signal.glassTintStrength).hexString ?? "none"
                let lens = DS.Signal.lensValue(signal, context)?.hexString ?? "none"
                recipe = "regular.tint(\(tint)) → lens \(lens)"
            }
        }
        return GlassResolution(
            tier: tier,
            signal: signal,
            usesRealGlass: true,
            glassRecipe: recipe,
            solidFill: nil,
            borderColor: nil,
            borderWidth: 0
        )
    }

    public var description: String {
        if usesRealGlass {
            return "glass \(glassRecipe ?? "regular")"
        }
        let fill = solidFill?.hexString ?? "none"
        let border = borderColor?.hexString ?? "none"
        return "solid \(fill) border \(border) @ \(String(format: "%.1f", borderWidth))pt"
    }
}

// MARK: - The container

/// `GlassEffectContainer` with the design system's merge distance.
///
/// **This is the thing that separates real glass from blurry rectangles.** Two adjacent
/// `.glassEffect` views render two independent blurs; the backdrop is sampled twice, the edges
/// meet in a hard seam, and the result looks like two translucent divs. Inside a container they
/// are resolved as *one lens* — the highlights run across the group, and when they move close
/// enough they merge, the way two drops of water do.
///
/// Every cluster of two or more glass elements lives in one of these. Non-negotiable, and
/// `GlassLintTests.everyGlassClusterHasAContainer` fails the build otherwise.
///
/// One container per *group*, not per toolbar: the clipboard controls and the font controls are
/// two lenses that should stay two lenses, because they are two ideas. Merging the whole ribbon
/// into a single slab loses the grouping that makes a ribbon usable.
public struct GlassCluster<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = DS.Space.glassMerge, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

// MARK: - Entry points

public extension View {
    /// Chrome glass in an explicit shape.
    func glassSurface(
        _ tier: GlassTier,
        in shape: some Shape,
        context: AppearanceContext,
        signal: DS.SignalKind = .neutral
    ) -> some View {
        modifier(GlassSurface(shape: shape, tier: tier, context: context, signal: signal))
    }

    /// A floating capsule: the stats pill, the refresh pill, the sync chip.
    ///
    /// `frosted` swaps the plain lens for the ``GlassTier/hud`` frost. A signal outranks a
    /// frost: a tinted surface is saying something, and the saying wins.
    func glassPill(
        context: AppearanceContext,
        signal: DS.SignalKind = .neutral,
        frosted: Bool = false
    ) -> some View {
        modifier(
            GlassSurface(
                shape: Capsule(style: .continuous),
                tier: signal != .neutral ? .signal : (frosted ? .hud : .floating),
                context: context,
                signal: signal
            )
        )
    }

    /// A floating card at ``DS/Radius/card``: the diff panel, the command palette, the launcher.
    func glassCard(
        context: AppearanceContext,
        radius: CGFloat = DS.Radius.card,
        signal: DS.SignalKind = .neutral,
        frosted: Bool = false
    ) -> some View {
        modifier(
            GlassSurface(
                shape: DS.Radius.shape(radius),
                tier: signal != .neutral ? .signal : (frosted ? .hud : .floating),
                context: context,
                signal: signal
            )
        )
    }

    /// An edge-anchored chrome bar: the toolbar, the formula bar, the tab bar, the sidebar.
    func glassChrome(context: AppearanceContext, radius: CGFloat = DS.Radius.panel) -> some View {
        modifier(
            GlassSurface(
                shape: DS.Radius.shape(radius),
                tier: .chrome,
                context: context
            )
        )
    }

    /// The opaque plane everything else floats above.
    ///
    /// `.backgroundExtensionEffect()` is the second half of the glass illusion and is easy to
    /// skip. Without it the grid stops at the toolbar's edge and you get a hard line with glass
    /// on one side and content on the other — which immediately reads as a translucent rectangle
    /// pasted over a view. With it, the grid's own pixels are mirrored and blurred out under the
    /// chrome, so there is something real for the lens to refract. It is the difference between
    /// glass *over* the document and glass *next to* it.
    ///
    /// The fill is the grid canvas, not a material, because §3's whole discipline is that there
    /// is exactly one opaque plane and this is it.
    func gridPlane(_ context: AppearanceContext) -> some View {
        background(GridTheme.resolved(context).canvas.color)
            .backgroundExtensionEffect()
    }
}

// MARK: - Morphing

/// Identities for the pill→panel morph.
///
/// `glassEffectID` needs a stable, `Hashable` id shared by the two shapes that are meant to be the
/// *same lens at two sizes*. Using a raw string at both call sites works right up until somebody
/// typos one of them, at which point the morph silently degrades into a cross-fade and no test
/// catches it. So: an enum.
public enum GlassMorphID: String, Sendable, Hashable, CaseIterable {
    /// The refresh pill and the diff panel. PLAN.md §1.2 — the app's signature interaction.
    case syncSurface
    /// The selection stats pill and its expanded form.
    case selectionStats
    /// The command palette's field and its results card.
    case commandPalette
    /// The sheet-chat bubble and its conversation panel.
    case chatSurface
}

public extension View {
    /// Marks this view as one end of a morph. Both ends must use the same id **and** be inside
    /// the same ``GlassCluster``, or the system has nothing to interpolate between.
    func glassMorph(_ id: GlassMorphID, in namespace: Namespace.ID) -> some View {
        glassEffectID(id, in: namespace)
    }

    /// How the lens travels between the two ends of a morph.
    ///
    /// `.matchedGeometry` is the liquid one: the capsule's geometry is carried into the card's,
    /// so the surface *stretches* rather than one shape fading out under another. It is the whole
    /// reason the pill→panel transition is worth building.
    ///
    /// Under `reduceMotion` it becomes `.identity`, which leaves the two shapes to cross-fade.
    /// Somebody who has asked the system for less motion should not be handed the app's most
    /// motion-heavy moment as a reward for using its best feature.
    func glassMorphTransition(_ context: AppearanceContext) -> some View {
        glassEffectTransition(context.reduceMotion ? .identity : .matchedGeometry)
    }
}
