import Foundation
import GridKit

/// Serialises every test that reads ``GridKit/GridInstrumentation``'s counters.
///
/// # The bug this exists to stop
///
/// The counters are **one set of atomics for the whole process**, and Swift Testing runs suites in
/// parallel. So the shape every one of these tests uses —
///
/// ```swift
/// GridInstrumentation.reset()
/// … do the thing …
/// #expect(GridInstrumentation.snapshot().axisLookups == 4)
/// ```
///
/// is only measuring *this* test when no other test happens to be drawing at the same moment.
/// When one is, the reset wipes its partial count and the snapshot adds its lookups to ours.
///
/// It surfaced as `AxisMetricsTests` finding five axis lookups where the arithmetic says four,
/// in roughly one full-suite run in three, while passing every time in isolation — which is the
/// signature of shared state rather than of a real regression. Three test files already shared
/// these counters; adding a fourth heavy user (the change-highlight work assertions) raised the
/// collision odds enough to make it show.
///
/// Counting could have been made per-task instead, and that would be the better fix — but the
/// counters are production API that the renderer increments on a hot path, and slowing that down
/// to tidy a test is the wrong trade. Serialising the handful of tests that read them costs
/// nothing anybody will notice.
///
/// # Using it
///
/// The block must span the reset **and every read that follows it** — a snapshot taken after the
/// block has ended is unguarded again, which is exactly the bug. Measured regions are synchronous
/// on purpose: nothing here may suspend while holding the lock.
enum GridWork {
    private static let mutex = NSLock()

    /// Zeroes the counters, runs `body` with nothing else measuring, and returns its result.
    static func measured<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        GridInstrumentation.reset()
        return try body()
    }
}
