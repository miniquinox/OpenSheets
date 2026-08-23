import Foundation

/// A centred interval tree over integer spans.
///
/// This is the structure that stops `SUM(A:A)` from costing 1,048,576 graph edges. A range
/// dependency is stored **once**, as the interval it covers; asking "which formulas depend on
/// row 7?" is then a tree descent that touches O(log n + k) intervals rather than a scan of
/// every edge, and adding a whole-column dependency costs one entry rather than a million.
///
/// Built once from a batch and queried many times. Rebuilding is O(n log n), which is why
/// ``DependencyGraph`` rebuilds one sheet's index per edit rather than the whole workbook's.
struct IntervalIndex<Payload> {
    struct Entry {
        var lower: Int
        var upper: Int
        var payload: Payload
    }

    private struct Node {
        var centre: Int
        /// Indices into ``entries``, ascending by `lower`.
        var byLower: [Int]
        /// Indices into ``entries``, descending by `upper`.
        var byUpper: [Int]
        var left: Int
        var right: Int
    }

    private var entries: [Entry] = []
    private var nodes: [Node] = []
    private var root = -1

    /// Intervals held.
    var count: Int { entries.count }

    /// Whether the index holds nothing.
    var isEmpty: Bool { entries.isEmpty }

    init() {}

    init(_ entries: [Entry]) {
        self.entries = entries
        guard !entries.isEmpty else { return }
        root = build(Array(entries.indices))
    }

    /// Every payload whose interval contains `point`.
    func payloads(containing point: Int) -> [Payload] {
        payloads(overlapping: point, point)
    }

    /// Every payload whose interval overlaps `lower...upper`.
    func payloads(overlapping lower: Int, _ upper: Int) -> [Payload] {
        guard root >= 0 else { return [] }
        var result: [Payload] = []
        var stack = [root]
        while let index = stack.popLast() {
            let node = nodes[index]
            if upper < node.centre {
                for entry in node.byLower {
                    guard entries[entry].lower <= upper else { break }
                    result.append(entries[entry].payload)
                }
                if node.left >= 0 { stack.append(node.left) }
            } else if lower > node.centre {
                for entry in node.byUpper {
                    guard entries[entry].upper >= lower else { break }
                    result.append(entries[entry].payload)
                }
                if node.right >= 0 { stack.append(node.right) }
            } else {
                for entry in node.byLower { result.append(entries[entry].payload) }
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
            }
        }
        return result
    }

    /// Recursion depth here is O(log n) — a balanced split by median centre — so this is the
    /// one place in the module that recurses, and it cannot go deeper than about 40 levels for
    /// any workbook that fits in memory.
    private mutating func build(_ indices: [Int]) -> Int {
        guard !indices.isEmpty else { return -1 }
        var midpoints = indices.map { (entries[$0].lower + entries[$0].upper) / 2 }
        midpoints.sort()
        let centre = midpoints[midpoints.count / 2]

        var here: [Int] = []
        var left: [Int] = []
        var right: [Int] = []
        for index in indices {
            if entries[index].upper < centre {
                left.append(index)
            } else if entries[index].lower > centre {
                right.append(index)
            } else {
                here.append(index)
            }
        }
        // Every interval straddles the centre, so the split made no progress: stop here rather
        // than recurse forever.
        if here.count == indices.count {
            let node = Node(
                centre: centre,
                byLower: here.sorted { entries[$0].lower < entries[$1].lower },
                byUpper: here.sorted { entries[$0].upper > entries[$1].upper },
                left: -1,
                right: -1
            )
            nodes.append(node)
            return nodes.count - 1
        }

        let leftIndex = build(left)
        let rightIndex = build(right)
        let node = Node(
            centre: centre,
            byLower: here.sorted { entries[$0].lower < entries[$1].lower },
            byUpper: here.sorted { entries[$0].upper > entries[$1].upper },
            left: leftIndex,
            right: rightIndex
        )
        nodes.append(node)
        return nodes.count - 1
    }
}

extension IntervalIndex: Sendable where Payload: Sendable {}
extension IntervalIndex.Entry: Sendable where Payload: Sendable {}
