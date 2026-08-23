import Foundation

/// A least-recently-used cache with a hard ceiling and O(1) everything.
///
/// # Why not a dictionary plus a periodic sweep
///
/// The obvious cheap-to-write version — let the dictionary grow past capacity, then sort by last
/// use and drop the oldest quarter — was measured costing one over-budget frame every twenty-odd
/// during a fling. The sort is O(n log n) over thousands of keys and it lands inside one unlucky
/// frame. A p99 is exactly the statistic that notices.
///
/// So this is a real LRU: a fixed array of nodes threaded into a doubly linked list *by index*,
/// with a dictionary mapping key to slot. The node array never grows past ``capacity``, eviction
/// reuses the tail's slot rather than allocating, and no frame ever pays for another frame's
/// insertions.
struct BoundedLRU<Key: Hashable, Value> {
    private struct Node {
        var key: Key
        var value: Value
        /// Slot of the more recently used neighbour, or `-1` at the head.
        var previous: Int
        /// Slot of the less recently used neighbour, or `-1` at the tail.
        var next: Int
    }

    private var nodes: [Node] = []
    private var slots: [Key: Int] = [:]
    private var head = -1
    private var tail = -1

    /// Entries held before the least recently used one is dropped.
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(4, capacity)
        nodes.reserveCapacity(self.capacity)
        slots.reserveCapacity(self.capacity)
    }

    /// Entries currently held. Never exceeds ``capacity``.
    var count: Int { nodes.count }

    /// The cached value, or the one `make` produces, which is then cached.
    ///
    /// `hit` reports which happened, so the caller can keep its own counters without a second
    /// lookup.
    mutating func value(for key: Key, hit: inout Bool, make: () -> Value) -> Value {
        if let slot = slots[key] {
            hit = true
            moveToHead(slot)
            return nodes[slot].value
        }
        hit = false
        let made = make()
        insert(key, made)
        return made
    }

    /// Drops everything.
    mutating func removeAll() {
        nodes.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        head = -1
        tail = -1
    }

    // MARK: - The list

    private mutating func insert(_ key: Key, _ value: Value) {
        if nodes.count < capacity {
            nodes.append(Node(key: key, value: value, previous: -1, next: head))
            let slot = nodes.count - 1
            if head >= 0 { nodes[head].previous = slot }
            head = slot
            if tail < 0 { tail = slot }
            slots[key] = slot
            return
        }
        // Full: reuse the least recently used slot. One dictionary removal, one insertion and
        // three pointer writes — the same cost every time, so no frame is special.
        let slot = tail
        slots.removeValue(forKey: nodes[slot].key)
        detach(slot)
        nodes[slot].key = key
        nodes[slot].value = value
        attachAtHead(slot)
        slots[key] = slot
    }

    private mutating func moveToHead(_ slot: Int) {
        guard head != slot else { return }
        detach(slot)
        attachAtHead(slot)
    }

    private mutating func detach(_ slot: Int) {
        let previous = nodes[slot].previous
        let next = nodes[slot].next
        if previous >= 0 { nodes[previous].next = next } else if head == slot { head = next }
        if next >= 0 { nodes[next].previous = previous } else if tail == slot { tail = previous }
        nodes[slot].previous = -1
        nodes[slot].next = -1
    }

    private mutating func attachAtHead(_ slot: Int) {
        nodes[slot].previous = -1
        nodes[slot].next = head
        if head >= 0 { nodes[head].previous = slot }
        head = slot
        if tail < 0 { tail = slot }
    }
}
