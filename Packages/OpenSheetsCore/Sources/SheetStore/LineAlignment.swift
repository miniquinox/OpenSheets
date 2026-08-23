import Foundation

/// Aligns two sequences of content hashes, so a diff can tell *"a row was inserted"* from
/// *"every row below it changed"* (PLAN.md §6.4).
///
/// **Why not a textbook LCS.** The classic dynamic-programming LCS is O(n·m). Inserting one
/// row into a 10,000-row sheet would be 10⁸ cell operations — about a second of pure table
/// filling, for an answer that is "one insert at index 5". Instead:
///
/// 1. **Trim the common prefix and suffix.** In the case that actually happens — an agent
///    edited a few rows, or inserted one — this alone reduces the problem to a handful of
///    entries and the rest is free.
/// 2. **Myers' O(ND) greedy algorithm** on what is left, where D is the edit distance. For
///    near-identical inputs D is tiny, so this is effectively linear.
/// 3. **A hard cap on D.** Two genuinely unrelated sheets have D ≈ n + m, and grinding
///    through that would be a hang. Past the cap the alignment gives up and says so, and the
///    caller falls back to a straight positional comparison. A structural insert we failed to
///    notice is a worse diff; a hang is a worse product.
enum LineAlignment {
    /// One aligned pair, or an unpaired entry on one side.
    enum Step: Hashable {
        /// Present in both, at these indices.
        case matched(before: Int, after: Int)
        /// Present only in the new sequence.
        case inserted(after: Int)
        /// Present only in the old sequence.
        case deleted(before: Int)
    }

    struct Result {
        /// The alignment, in index order.
        var steps: [Step]
        /// The cap was hit and `steps` is a positional fallback rather than a real alignment.
        var gaveUp: Bool

        /// Old index → new index for everything that lined up.
        var matches: [Int: Int] {
            var result: [Int: Int] = [:]
            for step in steps {
                if case let .matched(before, after) = step { result[before] = after }
            }
            return result
        }
    }

    /// Aligns `before` and `after`.
    ///
    /// - Parameter maximumEditDistance: the D cap from the note above. The default scales with
    ///   the input but stays bounded, so a 1 M-row sheet cannot turn this into a hang.
    static func align(
        before: [UInt64],
        after: [UInt64],
        maximumEditDistance: Int? = nil
    ) -> Result {
        // The ceiling is a memory bound as much as a time one: the trace is O(D²) ints, so
        // D = 1024 is about 17 MB and D = 4096 would be 270 MB. Past the cap the fallback
        // gives the same answer anyway for the case that matters — two sequences of equal
        // length where everything differs pairs up positionally either way.
        let limit = maximumEditDistance ?? min(1024, max(256, (before.count + after.count) / 8))

        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix,
              suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }

        let oldMiddle = Array(before[prefix ..< (before.count - suffix)])
        let newMiddle = Array(after[prefix ..< (after.count - suffix)])

        var steps: [Step] = []
        steps.reserveCapacity(prefix + suffix + oldMiddle.count + newMiddle.count)
        for index in 0 ..< prefix { steps.append(.matched(before: index, after: index)) }

        var gaveUp = false
        if oldMiddle.isEmpty {
            for index in 0 ..< newMiddle.count { steps.append(.inserted(after: prefix + index)) }
        } else if newMiddle.isEmpty {
            for index in 0 ..< oldMiddle.count { steps.append(.deleted(before: prefix + index)) }
        } else if let middle = myers(oldMiddle, newMiddle, limit: limit) {
            for step in middle {
                switch step {
                case let .matched(before: oldIndex, after: newIndex):
                    steps.append(.matched(before: prefix + oldIndex, after: prefix + newIndex))
                case let .inserted(after: newIndex):
                    steps.append(.inserted(after: prefix + newIndex))
                case let .deleted(before: oldIndex):
                    steps.append(.deleted(before: prefix + oldIndex))
                }
            }
        } else {
            gaveUp = true
            // Positional fallback: pair them up index for index and report the tail as
            // inserted or deleted. Not an alignment, but a well-defined one-to-one mapping
            // that the caller can still diff cell by cell.
            let shared = min(oldMiddle.count, newMiddle.count)
            for index in 0 ..< shared { steps.append(.matched(before: prefix + index, after: prefix + index)) }
            for index in shared ..< oldMiddle.count { steps.append(.deleted(before: prefix + index)) }
            for index in shared ..< newMiddle.count { steps.append(.inserted(after: prefix + index)) }
        }

        for index in 0 ..< suffix {
            steps.append(.matched(before: before.count - suffix + index, after: after.count - suffix + index))
        }
        return Result(steps: steps, gaveUp: gaveUp)
    }

    /// Pairs up runs of deletions and insertions that sit next to each other.
    ///
    /// Myers works on exact equality, so a row where **one cell** changed comes back as
    /// "delete the old row, insert a new one". Left alone, editing a single cell in a
    /// forty-column sheet would report forty removals and forty additions instead of one
    /// changed cell — and the structural detector would call it a delete-and-insert rather
    /// than nothing structural at all.
    ///
    /// So a replace block — consecutive deletions and insertions with no match between them —
    /// is paired off positionally, exactly as `diff` reports a `c` block. `min(deleted, inserted)`
    /// pairs become matches, and only the genuine surplus stays structural. A pure insert has
    /// no deletions to pair with, so the 10,000-row case is untouched.
    static func pairingReplacements(_ steps: [Step]) -> [Step] {
        var result: [Step] = []
        result.reserveCapacity(steps.count)
        var deletions: [Int] = []
        var insertions: [Int] = []

        func flush() {
            let paired = min(deletions.count, insertions.count)
            for index in 0 ..< paired {
                result.append(.matched(before: deletions[index], after: insertions[index]))
            }
            for index in paired ..< deletions.count { result.append(.deleted(before: deletions[index])) }
            for index in paired ..< insertions.count { result.append(.inserted(after: insertions[index])) }
            deletions.removeAll(keepingCapacity: true)
            insertions.removeAll(keepingCapacity: true)
        }

        for step in steps {
            switch step {
            case .matched:
                flush()
                result.append(step)
            case let .deleted(index):
                deletions.append(index)
            case let .inserted(index):
                insertions.append(index)
            }
        }
        flush()
        return result
    }

    /// Myers' greedy algorithm with a trace, returning `nil` once D exceeds `limit`.
    ///
    /// `trace[d]` is the furthest-reaching x for each diagonal k after d steps; walking it
    /// backwards recovers the edit script. Storing the trace costs O(D²) memory, which is why
    /// `limit` matters as much for space as for time.
    private static func myers(_ before: [UInt64], _ after: [UInt64], limit: Int) -> [Step]? {
        let n = before.count
        let m = after.count
        let maxDistance = min(limit, n + m)
        let offset = maxDistance + 1
        var v = [Int](repeating: 0, count: 2 * maxDistance + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(maxDistance + 1)

        for d in 0 ... maxDistance {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, before[x] == after[y] {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    return script(trace: trace, distance: d, offset: offset, before: before, after: after)
                }
                k += 2
            }
        }
        return nil
    }

    /// Walks the trace backwards into an edit script.
    private static func script(
        trace: [[Int]],
        distance: Int,
        offset: Int,
        before: [UInt64],
        after: [UInt64]
    ) -> [Step] {
        let n = before.count
        let m = after.count
        var steps: [Step] = []
        var x = n
        var y = m

        var d = distance
        while d > 0 {
            let v = trace[d]
            let k = x - y
            let previousK: Int = if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                k + 1
            } else {
                k - 1
            }
            let previousX = v[previousK + offset]
            let previousY = previousX - previousK

            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                steps.append(.matched(before: x, after: y))
            }
            if x > previousX {
                x -= 1
                steps.append(.deleted(before: x))
            } else if y > previousY {
                y -= 1
                steps.append(.inserted(after: y))
            }
            d -= 1
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            steps.append(.matched(before: x, after: y))
        }
        while x > 0 {
            x -= 1
            steps.append(.deleted(before: x))
        }
        while y > 0 {
            y -= 1
            steps.append(.inserted(after: y))
        }
        return Array(steps.reversed())
    }
}
