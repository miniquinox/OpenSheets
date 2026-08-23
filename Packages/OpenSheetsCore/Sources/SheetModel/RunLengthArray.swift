import Foundation

/// A conceptually infinite array where almost every element is the same.
///
/// This exists for column widths and row heights. A sheet has 16,384 columns and 1,048,576
/// rows; a real sheet customises maybe three of them. Storing a `Double` per column costs
/// 128 KB per sheet to say "default" 16,381 times, and the row array would be 8 MB. Storing
/// runs costs a handful of structs.
///
/// The representation is a sorted, non-overlapping list of runs whose values all differ from
/// ``defaultValue``; adjacent runs with equal values are merged on every mutation, so the run
/// count stays proportional to the number of *distinct customised bands*, not to how many
/// times you wrote to it. Reading is a binary search over runs.
///
/// Indices below zero read as ``defaultValue`` and are ignored on write. There is no upper
/// bound — the array is as long as you ask it about.
public struct RunLengthArray<Element: Equatable & Sendable>: Sendable {
    /// A contiguous band of indices sharing one value.
    public struct Run: Sendable, Equatable {
        /// Inclusive index range.
        public var range: ClosedRange<Int>
        /// The value across that range. Never equal to the array's default.
        public var value: Element

        public init(range: ClosedRange<Int>, value: Element) {
            self.range = range
            self.value = value
        }
    }

    /// What every index reads as unless a run says otherwise.
    public let defaultValue: Element

    /// Sorted by `range.lowerBound`, non-overlapping, never holding ``defaultValue``,
    /// with adjacent equal runs merged.
    private var storage: [Run]

    /// An array where everything is `defaultValue`.
    public init(defaultValue: Element) {
        self.defaultValue = defaultValue
        storage = []
    }

    /// An array pre-seeded with runs. They are applied in order, so later runs win where
    /// they overlap — which is what a parser wants when a file lists overlapping `<col>`
    /// elements.
    public init(defaultValue: Element, runs: [Run]) {
        self.defaultValue = defaultValue
        storage = []
        for run in runs {
            setValue(run.value, in: run.range)
        }
    }

    // MARK: - Reading

    /// The value at `index`. O(log runCount).
    public subscript(index: Int) -> Element {
        get {
            guard index >= 0 else { return defaultValue }
            let position = firstRunIndex(endingAtOrAfter: index)
            if position < storage.count, storage[position].range.contains(index) {
                return storage[position].value
            }
            return defaultValue
        }
        set { setValue(newValue, in: index ... index) }
    }

    /// How many runs are actually stored. The number this type exists to keep small — assert
    /// on it in tests rather than trusting that a splice did the right thing.
    public var runCount: Int { storage.count }

    /// Whether every index reads as ``defaultValue``.
    public var isUniform: Bool { storage.isEmpty }

    /// Every stored run, ascending. Excludes default-valued spans, which is the point.
    public var runs: [Run] { storage }

    /// The stored runs overlapping `range`, clipped to it, ascending.
    ///
    /// Gaps in the result are default-valued. The grid renderer walks this to paint a
    /// visible band without materialising one entry per column.
    public func runs(in range: ClosedRange<Int>) -> [Run] {
        var result: [Run] = []
        var position = firstRunIndex(endingAtOrAfter: range.lowerBound)
        while position < storage.count, storage[position].range.lowerBound <= range.upperBound {
            let run = storage[position]
            let lower = max(run.range.lowerBound, range.lowerBound)
            let upper = min(run.range.upperBound, range.upperBound)
            if lower <= upper { result.append(Run(range: lower ... upper, value: run.value)) }
            position += 1
        }
        return result
    }

    /// The highest index carrying a non-default value, or `nil` when the array is uniform.
    /// Used to work out how far a sheet's formatting extends past its data.
    public var lastCustomisedIndex: Int? { storage.last?.range.upperBound }

    // MARK: - Writing

    /// Sets every index in `range` to `value`, splitting and merging runs as needed.
    ///
    /// Writing ``defaultValue`` is the same as ``reset(_:)`` — it removes runs rather than
    /// storing a run of defaults, which is what keeps ``runCount`` honest.
    public mutating func setValue(_ value: Element, in range: ClosedRange<Int>) {
        let start = max(0, range.lowerBound)
        let end = range.upperBound
        guard end >= start else { return }

        let first = firstRunIndex(endingAtOrAfter: start)
        var last = first
        while last < storage.count, storage[last].range.lowerBound <= end {
            last += 1
        }

        var replacement: [Run] = []
        // A run that started before this write survives as a left fragment.
        if first < last, storage[first].range.lowerBound < start {
            replacement.append(Run(range: storage[first].range.lowerBound ... (start - 1), value: storage[first].value))
        }
        if value != defaultValue {
            replacement.append(Run(range: start ... end, value: value))
        }
        // A run that continues past this write survives as a right fragment.
        if first < last, storage[last - 1].range.upperBound > end {
            replacement.append(Run(
                range: (end + 1) ... storage[last - 1].range.upperBound,
                value: storage[last - 1].value
            ))
        }

        storage.replaceSubrange(first ..< last, with: replacement)
        coalesce(around: first, spanning: replacement.count)
    }

    /// Returns every index in `range` to ``defaultValue``.
    public mutating func reset(_ range: ClosedRange<Int>) {
        setValue(defaultValue, in: range)
    }

    /// Returns the whole array to ``defaultValue``.
    public mutating func resetAll() {
        storage.removeAll(keepingCapacity: true)
    }

    /// Opens `count` indices at `index`, shifting everything at or after it right.
    ///
    /// A run *straddling* the insertion point grows rather than splitting, which matches
    /// Excel: inserting a row in the middle of a band of 40pt rows gives you another 40pt row,
    /// not a default-height one. Pass `value` to force the new band to something specific.
    public mutating func insert(at index: Int, count: Int, value: Element? = nil) {
        guard count > 0, index >= 0 else { return }
        storage = storage.map { run in
            if run.range.lowerBound >= index {
                Run(range: (run.range.lowerBound + count) ... (run.range.upperBound + count), value: run.value)
            } else if run.range.upperBound >= index {
                Run(range: run.range.lowerBound ... (run.range.upperBound + count), value: run.value)
            } else {
                run
            }
        }
        if let value {
            setValue(value, in: index ... (index + count - 1))
        }
    }

    /// Closes `count` indices at `index`, shifting everything after them left.
    ///
    /// Runs entirely inside the deleted band disappear; runs overlapping it are trimmed.
    public mutating func remove(at index: Int, count: Int) {
        guard count > 0, index >= 0 else { return }
        let deleted = index ... (index + count - 1)
        var result: [Run] = []
        result.reserveCapacity(storage.count)

        for run in storage {
            if run.range.upperBound < deleted.lowerBound {
                result.append(run)
                continue
            }
            if run.range.lowerBound > deleted.upperBound {
                result.append(Run(
                    range: (run.range.lowerBound - count) ... (run.range.upperBound - count),
                    value: run.value
                ))
                continue
            }
            // Overlaps the deleted band: keep whatever sticks out on either side, joined.
            let survivingBefore = max(0, deleted.lowerBound - run.range.lowerBound)
            let survivingAfter = max(0, run.range.upperBound - deleted.upperBound)
            let total = survivingBefore + survivingAfter
            if total > 0 {
                let lower = min(run.range.lowerBound, deleted.lowerBound)
                result.append(Run(range: lower ... (lower + total - 1), value: run.value))
            }
        }

        storage = result
        coalesce(around: 0, spanning: storage.count)
    }

    // MARK: - Internals

    /// Index of the first run whose upper bound is at or after `index`. O(log runCount).
    private func firstRunIndex(endingAtOrAfter index: Int) -> Int {
        var low = 0
        var high = storage.count
        while low < high {
            let mid = (low + high) / 2
            if storage[mid].range.upperBound < index { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Merges adjacent equal-valued runs in a window around a mutation.
    private mutating func coalesce(around index: Int, spanning count: Int) {
        var position = max(0, index - 1)
        var budget = count + 2
        while position + 1 < storage.count, budget > 0 {
            if storage[position].value == storage[position + 1].value,
               storage[position].range.upperBound + 1 == storage[position + 1].range.lowerBound {
                storage[position] = Run(
                    range: storage[position].range.lowerBound ... storage[position + 1].range.upperBound,
                    value: storage[position].value
                )
                storage.remove(at: position + 1)
            } else {
                position += 1
            }
            budget -= 1
        }
    }
}

// MARK: - Conformances

extension RunLengthArray: Equatable {
    /// Two arrays are equal when they answer the same for every index — which, because runs
    /// are always normalised, is the same as having the same default and the same runs.
    public static func == (lhs: RunLengthArray, rhs: RunLengthArray) -> Bool {
        lhs.defaultValue == rhs.defaultValue && lhs.storage == rhs.storage
    }
}

extension RunLengthArray.Run: Hashable where Element: Hashable {}
extension RunLengthArray: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(defaultValue)
        hasher.combine(storage)
    }
}

extension RunLengthArray.Run: Codable where Element: Codable {
    private enum CodingKeys: String, CodingKey {
        case lower, upper, value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range.lowerBound, forKey: .lower)
        try container.encode(range.upperBound, forKey: .upper)
        try container.encode(value, forKey: .value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lower = try container.decode(Int.self, forKey: .lower)
        let upper = try container.decode(Int.self, forKey: .upper)
        guard lower <= upper else {
            throw DecodingError.dataCorruptedError(
                forKey: .upper, in: container, debugDescription: "run upper bound precedes its lower bound"
            )
        }
        self.init(range: lower ... upper, value: try container.decode(Element.self, forKey: .value))
    }
}

extension RunLengthArray: Codable where Element: Codable {
    private enum CodingKeys: String, CodingKey {
        case defaultValue, runs
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encode(storage, forKey: .runs)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultValue: try container.decode(Element.self, forKey: .defaultValue),
            runs: try container.decodeIfPresent([Run].self, forKey: .runs) ?? []
        )
    }
}

extension RunLengthArray: CustomStringConvertible {
    public var description: String {
        let described = storage.map { "\($0.range.lowerBound)…\($0.range.upperBound)=\($0.value)" }
        return "RunLengthArray(default: \(defaultValue), runs: [\(described.joined(separator: ", "))])"
    }
}

// MARK: - Geometry

extension RunLengthArray where Element == Double {
    /// Total extent of indices `0..<index` — the pixel offset of a row's top edge, or a
    /// column's left edge.
    ///
    /// O(runCount), not O(index): the default-valued gaps are multiplied, never walked. That
    /// is what lets the grid scroll to row 1,048,576 without a linear scan.
    public func offset(ofIndex index: Int) -> Double {
        guard index > 0 else { return 0 }
        var total = 0.0
        var covered = 0
        for run in storage {
            if run.range.lowerBound >= index { break }
            let lower = run.range.lowerBound
            let upper = min(run.range.upperBound, index - 1)
            total += Double(lower - covered) * defaultValue
            total += Double(upper - lower + 1) * run.value
            covered = upper + 1
        }
        if covered < index { total += Double(index - covered) * defaultValue }
        return total
    }

    /// Total extent of the indices in `range`, inclusive.
    public func extent(of range: ClosedRange<Int>) -> Double {
        offset(ofIndex: range.upperBound + 1) - offset(ofIndex: range.lowerBound)
    }

    /// The index whose band contains `offset`, clamped to `0 ..< limit`.
    ///
    /// The inverse of ``offset(ofIndex:)``, and the other half of virtualised scrolling: given
    /// a scroll position, which row is at the top. O(runCount).
    ///
    /// A zero or negative ``defaultValue`` would make this ambiguous — infinitely many hidden
    /// rows sit at the same offset — so it returns the first such index.
    public func index(atOffset offset: Double, limit: Int) -> Int {
        guard offset > 0, limit > 0 else { return 0 }
        var total = 0.0
        var covered = 0

        for run in storage {
            if covered >= limit { break }
            // The default-valued gap before this run.
            if run.range.lowerBound > covered {
                let gap = min(run.range.lowerBound, limit) - covered
                if defaultValue > 0 {
                    let span = Double(gap) * defaultValue
                    if total + span > offset {
                        return min(covered + Int((offset - total) / defaultValue), limit - 1)
                    }
                    total += span
                }
                covered += gap
                if covered >= limit { break }
            }
            let upper = min(run.range.upperBound, limit - 1)
            guard upper >= run.range.lowerBound else { continue }
            let count = upper - max(run.range.lowerBound, covered) + 1
            if run.value > 0 {
                let span = Double(count) * run.value
                if total + span > offset {
                    return min(covered + Int((offset - total) / run.value), limit - 1)
                }
                total += span
            }
            covered = upper + 1
        }

        if covered < limit, defaultValue > 0 {
            return min(covered + Int((offset - total) / defaultValue), limit - 1)
        }
        return limit - 1
    }
}
