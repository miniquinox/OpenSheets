import AppKit
import DocumentCore
import GridKit
import SheetModel
import TestSupport
import Testing

/// The grid, in a real `NSWindow`.
///
/// `GridKitTests` exercises the renderer and the geometry, and both are correct. What nothing
/// exercised before Wave 2 is `GridHostView` **attached to a window**, which is the only place the
/// interaction between `NSScrollView.contentInsets` and `addFloatingSubview(_:for:)` showed up —
/// and it is where the row and column headers used to land in the wrong place.
///
/// The defect is fixed in `GridKit` now: the headers, the frozen panes and the editor are plain
/// subviews of the host, framed in host coordinates, and nothing floats. The workaround that used
/// to live here — `GridHeaderAlignmentFix`, which rewrote each floating container's `bounds.origin`
/// on every scroll — is gone with it.
///
/// These tests stay, pointed at the fixed behaviour, because the app is the only place the whole
/// arrangement is real: `GridKitTests` proves the frames, this proves the frames survive being
/// composed with the shell's own insets.
@Suite(.serialized)
@MainActor
struct GridIntegrationTests {
    /// Every header draws where it was laid out.
    ///
    /// The old failure was worth one line of arithmetic: a view laid out at host `(0, 22)` that
    /// AppKit had re-parented into a container at `(46, 22)` *drew* at `(46, 44)`. So the claim
    /// worth asserting is not "the frame is right" — it always was — but "the frame and the pixels
    /// agree", which is what `convert(_:to:)` answers.
    @Test func everyHeaderDrawsWhereItWasLaidOut() throws {
        let host = try Self.hostInWindow()
        let insets = host.contentScrollView.contentInsets
        #expect(insets.left > 0, "GridKit uses contentInsets to make room for the row header")
        #expect(insets.top > 0, "…and for the column header")

        for view in Self.headerViews(in: host) {
            let drawn = view.convert(view.bounds, to: host)
            #expect(
                drawn == view.frame,
                "\(type(of: view)) is laid out at \(view.frame) and draws at \(drawn)"
            )
        }
    }

    /// Nothing in the grid is a floating subview any more.
    ///
    /// Stated as a structural fact rather than left implied, because "it looks right" is exactly
    /// what was true of the frames while the pixels were wrong.
    @Test func nothingFloatsInsideTheScrollView() throws {
        let host = try Self.hostInWindow()
        let inScrollView = Self.descendants(of: host.contentScrollView).map(Self.name(of:))
        for name in Self.headerViewNames {
            #expect(!inScrollView.contains(name), "\(name) is back inside the scroll view")
        }
        for view in Self.headerViews(in: host) {
            #expect(view.superview === host, "\(type(of: view)) should be a child of the host itself")
        }
    }

    /// The row numbers label the rows, and the column letters label the columns.
    ///
    /// The assertion the whole class of bug fails: not where a view *is*, but whether the label and
    /// the thing it labels land on the same pixels in the window.
    @Test func headersLineUpWithTheCellsTheyLabel() throws {
        let host = try Self.hostInWindow()
        let geometry = host.model.geometry
        let document = try #require(host.contentScrollView.documentView)
        let rowHeader = try #require(Self.view(named: "GridRowHeaderView", in: host))
        let columnHeader = try #require(Self.view(named: "GridColumnHeaderView", in: host))

        for row in 0 ..< 3 {
            let sheetY = geometry.sheetRect(row: row, column: 0).minY
            let label = rowHeader.convert(CGPoint(x: 0, y: sheetY - host.scrollOrigin.y), to: nil)
            let cell = document.convert(
                geometry.documentRect(fromSheet: geometry.sheetRect(row: row, column: 0)).origin, to: nil
            )
            #expect(abs(label.y - cell.y) < 0.5, "row \(row + 1): number at \(label.y), cells at \(cell.y)")
        }

        for column in 0 ..< 3 {
            let sheetX = geometry.sheetRect(row: 0, column: column).minX
            let label = columnHeader.convert(CGPoint(x: sheetX - host.scrollOrigin.x, y: 0), to: nil)
            let cell = document.convert(
                geometry.documentRect(fromSheet: geometry.sheetRect(row: 0, column: column)).origin, to: nil
            )
            #expect(abs(label.x - cell.x) < 0.5, "column \(column + 1): letter at \(label.x), cells at \(cell.x)")
        }
    }

    /// The shell's own insets — the chrome the grid bleeds under, the pills it floats — compose
    /// with the grid's without moving anything out of alignment.
    @Test func theShellsInsetsComposeWithTheGridsOwn() throws {
        let plain = try Self.hostInWindow()
        let bare = plain.contentScrollView.contentInsets
        let viewport = plain.bodyViewportSize

        let chrome = GridInsets(top: 96, left: 0, bottom: 44, right: 0)
        let host = try Self.hostInWindow(insets: chrome)
        let insets = host.contentScrollView.contentInsets
        #expect(Double(insets.top) == Double(bare.top) + chrome.top)
        #expect(Double(insets.bottom) == chrome.bottom)
        // Scroll range, not a mask: the viewport gives up exactly what was reserved.
        #expect(Double(host.bodyViewportSize.height) == Double(viewport.height) - chrome.top - chrome.bottom)

        let corner = try #require(Self.view(named: "GridCornerView", in: host))
        #expect(corner.frame.origin == CGPoint(x: chrome.left, y: chrome.top))
        for view in Self.headerViews(in: host) {
            #expect(view.convert(view.bounds, to: host) == view.frame)
        }
    }

    /// The half of the grid that was always right in a live window, kept so a regression in the
    /// body pane cannot hide behind the header assertions.
    @Test func theBodyPaneAndGeometryAreCorrectInALiveWindow() throws {
        let host = try Self.hostInWindow()
        #expect(host.contentScrollView.frame == host.bounds)
        let visible = host.visibleRange
        #expect(visible.start == .origin)
        #expect(visible.rowCount > 1)
        #expect(host.bodyViewportSize.width > 0)
    }

    // MARK: - Harness

    /// Keeps the window alive for the length of the test: an `NSWindow` that goes out of scope
    /// takes its content view's layout with it.
    nonisolated(unsafe) private static var retained: [NSWindow] = []

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// `GridKit`'s header views are internal to it, so they are found by name — from outside the
    /// module, which is the vantage point this suite is asserting from.
    static let headerViewNames = ["GridRowHeaderView", "GridColumnHeaderView", "GridCornerView"]

    static func name(of view: NSView) -> String { String(describing: type(of: view)) }

    /// The three views the alignment claims are about, wherever they are attached.
    static func headerViews(in host: GridHostView) -> [NSView] {
        descendants(of: host).filter { headerViewNames.contains(name(of: $0)) }
    }

    static func view(named name: String, in host: GridHostView) -> NSView? {
        descendants(of: host).first { Self.name(of: $0) == name }
    }

    static func hostInWindow(
        insets: GridInsets = .zero,
        width: CGFloat = 900,
        height: CGFloat = 600
    ) throws -> GridHostView {
        let workbook = try Fixtures.workbook()
        let sheet = workbook.sheets[0]
        var options = GridOptions.default
        options.contentInsets = insets
        let host = GridHostView(
            model: GridRenderModel(
                sheet: sheet,
                styles: workbook.styles,
                dateSystem: .excel1900,
                theme: .light,
                options: options,
                geometry: GridGeometry(sheet: sheet, zoom: 1),
                merges: MergeIndex(sheet.merges),
                selection: GridSelection()
            )
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        retained.append(window)
        return host
    }
}
