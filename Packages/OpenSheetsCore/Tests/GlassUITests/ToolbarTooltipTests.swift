import AppKit
import SwiftUI
import Testing

@testable import GlassUI

/// Does a toolbar control actually end up with a tooltip?
///
/// `.help(_:)` is a promise about an `NSView.toolTip`, and the only way to know it was kept is to
/// host the real control in a real window and ask AppKit. Asserting that the modifier was *called*
/// would pass whether or not anything hovers — the mistake `FormulaBarFieldTests` was written to
/// stop repeating.
@Suite(.serialized)
@MainActor
struct ToolbarTooltipTests {
    /// Every tooltip string anywhere under a hosted view.
    private func tooltips(of view: some View) -> [String] {
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 80)
        hosting.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        window.displayIfNeeded()
        Retainer.windows.append(window)

        func walk(_ view: NSView) -> [String] {
            (view.toolTip.map { [$0] } ?? []) + view.subviews.flatMap(walk)
        }
        return walk(hosting)
    }

    private enum Retainer {
        nonisolated(unsafe) static var windows: [NSWindow] = []
    }

    @Test("A plain toolbar button carries its label and shortcut as a real tooltip")
    func iconButtonHasATooltip() {
        let button = GlassIconButton(
            symbol: "bold", label: "Bold", shortcut: "⌘B", context: .light
        ) {}
        #expect(tooltips(of: button).contains("Bold  ⌘B"))
    }

    @Test("So does one with no shortcut")
    func iconButtonWithoutShortcut() {
        let button = GlassIconButton(symbol: "text.append", label: "Wrap text", context: .light) {}
        #expect(tooltips(of: button).contains("Wrap text"))
    }

    /// The one that was silent. `ToolbarMenuButton` lays an invisible `Menu` over the button to
    /// take the click, so a tooltip on the button underneath is attached to a view the pointer
    /// never reaches.
    @Test("A toolbar button that opens a menu carries one too")
    func menuButtonHasATooltip() {
        let button = ToolbarMenuButton(
            symbol: "clipboard", label: "Paste", shortcut: "⌘V", context: .light
        ) {
            Button("Paste") {}
        }
        #expect(tooltips(of: button).contains("Paste  ⌘V"))
    }

    /// The question this suite was opened to answer, and the answer is worse than expected.
    ///
    /// It is not the glass button style. A plain `Button` with `.help` produces no `toolTip`
    /// either, so `.help(_:)` simply does not reach AppKit here — every hover title in this app was
    /// silent, not only the toolbar's. That is why ``View/hoverTitle(_:)`` exists and why it is
    /// used everywhere rather than only on the two toolbar controls that prompted it.
    ///
    /// Pinned as a `withKnownIssue` rather than deleted: if a future SwiftUI makes `.help` work,
    /// this starts passing, and that is the signal to delete the attachment rather than keep two
    /// mechanisms for one tooltip.
    @Test("`.help` alone still does not reach AppKit")
    func plainHelpDoesNotReachAppKit() {
        withKnownIssue("SwiftUI's .help sets no NSView.toolTip; hoverTitle exists because of it") {
            let plain = Button("x") {}.help("Plain tooltip")
            #expect(tooltips(of: plain).contains("Plain tooltip"))
        }
    }

    @Test("A disabled control still says what it is")
    func disabledStillExplainsItself() {
        let button = GlassIconButton(
            symbol: "scissors", label: "Cut", isEnabled: false, shortcut: "⌘X", context: .light
        ) {}
        #expect(tooltips(of: button).contains("Cut  ⌘X"))
    }
}

/// How long the pointer waits.
@Suite(.serialized)
@MainActor
struct HoverTitleTimingTests {
    /// Laid out in a real window, not merely constructed: an `NSViewRepresentable`'s view is not
    /// made until something asks for layout, so a hosting view on its own installs nothing. That
    /// is the difference between this test passing and it proving nothing.
    @Test("A laid-out control sets AppKit's tooltip delay to half a second")
    func delayIsInstalledOnLayout() {
        let hosting = NSHostingView(rootView: AnyView(
            GlassIconButton(symbol: "bold", label: "Bold", context: .light) {}
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        Kept.windows.append(window)

        #expect(
            UserDefaults.standard.integer(forKey: HoverTitleTiming.defaultsKey) == 500,
            "AppKit reads this key, in milliseconds, from the app's own domain"
        )
    }

    private enum Kept {
        nonisolated(unsafe) static var windows: [NSWindow] = []
    }

    @Test("It is registered rather than written, so a user's own setting survives")
    func registrationDoesNotOverwrite() {
        HoverTitleTiming.install()
        // A registered default is invisible to the persistent domain; anything found there was
        // put there by somebody, and registration must not have been what put it there.
        let persisted = UserDefaults.standard
            .persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[HoverTitleTiming.defaultsKey]
        #expect(persisted == nil)
    }
}
