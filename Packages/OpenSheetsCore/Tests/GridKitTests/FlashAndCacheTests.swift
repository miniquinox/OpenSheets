import SheetModel
import Testing
@testable import GridKit

@Suite("Agent-change flash")
@MainActor
struct FlashControllerTests {
    /// A controller whose clock a test can move.
    private func controller(duration: Double = 6) -> (FlashController, ManualFlashTicker, Clock) {
        let clock = Clock()
        let ticker = ManualFlashTicker()
        let controller = FlashController(duration: duration, ticker: ticker, now: { clock.now })
        return (controller, ticker, clock)
    }

    final class Clock {
        var now: Double = 0
    }

    @Test("Intensity starts high and reaches exactly zero at the end")
    func decayCurve() {
        var state = FlashState(duration: 6)
        let ref = CellRef(row: 3, column: 4)
        state.flash([ref], at: 100)
        #expect(state.intensity(of: ref, at: 100) == 1)
        #expect(state.intensity(of: ref, at: 103) > 0)
        #expect(state.intensity(of: ref, at: 103) < 1)
        #expect(state.intensity(of: ref, at: 106) == 0)
        #expect(state.intensity(of: ref, at: 1000) == 0)
        #expect(state.intensity(of: CellRef(row: 0, column: 0), at: 100) == 0)
    }

    @Test("Decay is monotonic")
    func monotonic() {
        var state = FlashState(duration: 6)
        let ref = CellRef.origin
        state.flash([ref], at: 0)
        var previous = 2.0
        for step in stride(from: 0.0, through: 6.0, by: 0.25) {
            let value = state.intensity(of: ref, at: step)
            #expect(value <= previous)
            previous = value
        }
        #expect(previous == 0)
    }

    @Test("The ticker starts on a flash and stops the moment nothing is left")
    func tickerLifecycle() {
        let (controller, ticker, clock) = controller(duration: 6)
        #expect(!controller.isRunning)

        controller.flash([CellRef(row: 1, column: 1)])
        #expect(controller.isRunning)
        #expect(ticker.startCount == 1)

        // Halfway: still decaying, still ticking.
        clock.now = 3
        ticker.fire()
        #expect(controller.isRunning)
        #expect(controller.state.isActive)

        // Past the end: the very next frame stops the link. A repeating timer that never stops
        // keeps the GPU awake and eats battery — this assertion is the whole reason the display
        // link is not a `Timer`.
        clock.now = 6.1
        ticker.fire()
        #expect(!controller.isRunning)
        #expect(!controller.state.isActive)
        #expect(ticker.stopCount == 1)
    }

    @Test("Eight seconds after a six-second flash, nothing is scheduled and nothing is tinted")
    func idleAfterEightSeconds() {
        let (controller, ticker, clock) = controller(duration: 6)
        controller.flash([CellRef(row: 10, column: 2), CellRef(row: 11, column: 2)])

        // Drive it frame by frame at 120 Hz for eight seconds of simulated time.
        var frames = 0
        while clock.now < 8, ticker.isRunning {
            clock.now += 1.0 / 120
            ticker.fire()
            frames += 1
        }
        #expect(!ticker.isRunning)
        #expect(controller.state.count == 0)
        #expect(controller.intensity(of: CellRef(row: 10, column: 2)) == 0)
        // It stopped well before eight seconds — one frame after the six-second mark.
        #expect(frames < 8 * 120)
        #expect(frames >= 6 * 120)
        // And it never restarted itself.
        #expect(ticker.startCount == 1)
        #expect(ticker.stopCount == 1)
    }

    @Test("A second flash restarts the decay without stacking tickers")
    func restart() {
        let (controller, ticker, clock) = controller(duration: 6)
        controller.flash([CellRef.origin])
        clock.now = 3
        controller.flash([CellRef(row: 1, column: 0)])
        #expect(ticker.startCount == 1)
        #expect(controller.state.count == 2)
        clock.now = 6.1
        ticker.fire()
        // The first cell has expired; the second has not, so the ticker keeps running.
        #expect(controller.state.count == 1)
        #expect(ticker.isRunning)
        clock.now = 9.1
        ticker.fire()
        #expect(!ticker.isRunning)
    }

    @Test("The invalidation rectangle covers only the flashed cells")
    func invalidationIsTargeted() {
        let (controller, _, _) = controller()
        var invalidated: [CellRange?] = []
        controller.onInvalidate = { invalidated.append($0) }
        controller.flash([CellRef(row: 5, column: 5), CellRef(row: 7, column: 9)])
        #expect(invalidated.last == CellRange(rows: 5 ... 7, columns: 5 ... 9))
    }

    @Test("Cancelling clears everything at once")
    func cancel() {
        let (controller, ticker, _) = controller()
        controller.flash([CellRef.origin])
        controller.cancel()
        #expect(!ticker.isRunning)
        #expect(!controller.state.isActive)
    }

    @Test("Flashing nothing does not start a timer")
    func emptyFlash() {
        let (controller, ticker, _) = controller()
        controller.flash([])
        #expect(!ticker.isRunning)
        #expect(ticker.startCount == 0)
    }
}

@Suite("Text layout cache")
@MainActor
struct TextLayoutCacheTests {
    private let font = FontKey(family: "", size: 12, isBold: false, isItalic: false)

    @Test("A repeat lookup is served from the cache, not re-shaped")
    func hits() {
        let cache = TextLayoutCache(capacity: 64)
        GridInstrumentation.reset()
        _ = cache.shaped("hello", font: font)
        #expect(GridInstrumentation.snapshot().textShapes == 1)
        _ = cache.shaped("hello", font: font)
        #expect(GridInstrumentation.snapshot().textShapes == 1)
        #expect(GridInstrumentation.snapshot().textCacheHits == 1)
    }

    @Test("The cache never exceeds its capacity, however many strings go through it")
    func bounded() {
        // The acceptance criterion is flat memory over a sixty-second scroll. That is a statement
        // about this ceiling: a million distinct strings must not become a million retained lines.
        let cache = TextLayoutCache(capacity: 128)
        for index in 0 ..< 20_000 {
            _ = cache.shaped("row \(index)", font: font)
            #expect(cache.count <= cache.capacity)
        }
        #expect(cache.count <= 128)
    }

    @Test("Eviction keeps what is being used")
    func evictionKeepsTheWorkingSet() {
        let cache = TextLayoutCache(capacity: 32)
        // A working set of eight strings, touched every round, against a stream of new ones.
        let working = (0 ..< 8).map { "keep \($0)" }
        for index in 0 ..< 500 {
            for text in working { _ = cache.shaped(text, font: font) }
            _ = cache.shaped("throwaway \(index)", font: font)
        }
        GridInstrumentation.reset()
        for text in working { _ = cache.shaped(text, font: font) }
        #expect(GridInstrumentation.snapshot().textShapes == 0)
        #expect(GridInstrumentation.snapshot().textCacheHits == working.count)
    }

    @Test("Colour is not part of the key, so one line serves every colour")
    func colourIsNotKeyed() {
        let cache = TextLayoutCache(capacity: 16)
        GridInstrumentation.reset()
        _ = cache.shaped("1,234.00", font: font)
        _ = cache.shaped("1,234.00", font: font)
        #expect(cache.count == 1)
        #expect(GridInstrumentation.snapshot().textShapes == 1)
    }

    @Test("Bold and italic are different keys")
    func traitsAreKeyed() {
        let cache = TextLayoutCache(capacity: 16)
        _ = cache.shaped("x", font: font)
        _ = cache.shaped("x", font: FontKey(family: "", size: 12, isBold: true, isItalic: false))
        #expect(cache.count == 2)
    }

    @Test("Font size is quantised so a pinch-zoom does not thrash the cache")
    func sizeQuantisation() {
        let a = FontKey(family: "Helvetica", size: 12.0, isBold: false, isItalic: false)
        let b = FontKey(family: "Helvetica", size: 12.02, isBold: false, isItalic: false)
        let c = FontKey(family: "Helvetica", size: 12.5, isBold: false, isItalic: false)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Digits are tabular, so numeric columns line up")
    func tabularFigures() {
        // The one typographic rule PLAN.md §3.4 calls non-negotiable. Proportional digits would
        // make these two strings different widths.
        let cache = TextLayoutCache(capacity: 16)
        let one = cache.width(of: "111111", font: font)
        let mixed = cache.width(of: "108734", font: font)
        #expect(abs(one - mixed) < 0.01)
    }

    @Test("Wrapped text is cached by width as well")
    func wrappedCache() {
        let cache = WrappedTextCache(capacity: 8)
        let lines = cache.lines("the quick brown fox jumps over the lazy dog", font: font, width: 60)
        #expect(lines.count > 1)
        let again = cache.lines("the quick brown fox jumps over the lazy dog", font: font, width: 60)
        #expect(again.count == lines.count)
        #expect(cache.count == 1)
        _ = cache.lines("the quick brown fox jumps over the lazy dog", font: font, width: 200)
        #expect(cache.count == 2)
    }

    @Test("The wrapped cache is bounded too")
    func wrappedBounded() {
        let cache = WrappedTextCache(capacity: 16)
        for index in 0 ..< 500 {
            _ = cache.lines("paragraph number \(index) with several words", font: font, width: 50)
            #expect(cache.count <= cache.capacity)
        }
    }
}
