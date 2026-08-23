import AppKit
import CoreGraphics
import CoreText
import Foundation
import SheetModel

/// Everything needed to pick a `CTFont`, and cheap to hash.
///
/// The size is quantised to a twentieth of a point so that a pinch-zoom does not produce a new
/// font — and therefore a new cache generation — on every frame.
public struct FontKey: Hashable, Sendable {
    public var family: String
    public var quantisedSize: Int
    public var isBold: Bool
    public var isItalic: Bool

    public init(family: String, size: Double, isBold: Bool, isItalic: Bool) {
        self.family = family
        quantisedSize = Int((size * 20).rounded())
        self.isBold = isBold
        self.isItalic = isItalic
    }

    /// The font size this key resolves to.
    public var size: Double { Double(quantisedSize) / 20 }

    /// The key for a cell's style at a zoom level.
    public init(style: FontStyle, zoom: Double, fallbackFamily: String, fallbackSize: Double) {
        let family = style.name.isEmpty ? fallbackFamily : style.name
        let size = style.size > 0 ? style.size : fallbackSize
        self.init(family: family, size: size * zoom, isBold: style.isBold, isItalic: style.isItalic)
    }
}

/// A laid-out line of text plus the metrics the renderer needs to place it.
///
/// Not `Sendable`: `CTLine` is not, and pretending otherwise would be a lie about a type that
/// only ever exists inside `@MainActor` drawing code anyway.
public struct ShapedLine {
    /// The shaped line. Immutable once created.
    public let line: CTLine
    /// Advance width in points.
    public let width: Double
    public let ascent: Double
    public let descent: Double
    public let leading: Double

    /// Distance from the top of a line box to the baseline.
    public var lineHeight: Double { ascent + descent + leading }

    init(line: CTLine, width: Double, ascent: Double, descent: Double, leading: Double) {
        self.line = line
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }
}

/// Resolves ``FontKey``s to `CTFont`s, **always with tabular figures**.
///
/// PLAN.md §3.4: "a spreadsheet where numeric columns don't align is a broken spreadsheet. This
/// is not a preference." Proportional digits are the default in SF and in most of the fonts real
/// workbooks name, so every font goes through the monospaced-numbers feature on the way out.
/// There is no opt-out, and no code path that skips it.
@MainActor
public enum FontResolver {
    private static var cache: [FontKey: CTFont] = [:]

    /// The font for a key, with tabular figures applied.
    public static func font(for key: FontKey) -> CTFont {
        if let existing = cache[key] { return existing }
        let resolved = build(key)
        // The number of distinct (family, size, traits) triples in a workbook is small — a few
        // dozen — so this cache is naturally bounded and needs no eviction. A pathological file
        // is capped rather than left to grow.
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = resolved
        return resolved
    }

    private static func build(_ key: FontKey) -> CTFont {
        let size = CGFloat(max(1, key.size))
        var base: CTFont

        if key.family.isEmpty {
            base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: key.isBold ? .semibold : .regular)
        } else {
            let candidate = CTFontCreateWithName(key.family as CFString, size, nil)
            let resolvedFamily = CTFontCopyFamilyName(candidate) as String
            // `CTFontCreateWithName` never fails; it substitutes. Detecting the substitution lets
            // a workbook that names Calibri get the system font's metrics rather than whatever
            // Core Text picked, which keeps auto-fit widths sane.
            if resolvedFamily.compare(key.family, options: .caseInsensitive) == .orderedSame {
                base = candidate
            } else {
                base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: key.isBold ? .semibold : .regular)
            }
        }

        var traits: CTFontSymbolicTraits = []
        if key.isBold { traits.insert(.traitBold) }
        if key.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
            base = styled
        }

        return applyTabularFigures(to: base, size: size)
    }

    /// Copies a font with the monospaced-numbers feature turned on.
    ///
    /// Fonts that have no such feature are unaffected, which is the correct outcome: a font whose
    /// digits are already fixed-width needs nothing done to it.
    private static func applyTabularFigures(to font: CTFont, size: CGFloat) -> CTFont {
        let settings: [[CFString: Any]] = [
            [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ],
        ]
        let descriptor = CTFontCopyFontDescriptor(font)
        let updated = CTFontDescriptorCreateCopyWithAttributes(
            descriptor,
            [kCTFontFeatureSettingsAttribute: settings] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(updated, size, nil)
    }

    /// Drops every resolved font. Tests use it; the app does not.
    public static func removeAll() { cache.removeAll() }
}

/// A bounded cache of shaped lines, keyed by text and font.
///
/// # Why bounded matters
///
/// Shaping is the expensive half of drawing text — `CTLineCreateWithAttributedString` runs the
/// shaper, and doing it per cell per frame is what makes a canvas grid stutter. Caching it is
/// obvious. Caching it *without a ceiling* is the bug: fling through a million distinct strings
/// and an unbounded cache is a million retained `CTLine`s, so memory climbs for as long as the
/// user scrolls. The acceptance criterion is flat memory over a sixty-second scroll, and that is
/// a statement about this class.
///
/// # Why eviction is O(1) and not a periodic sweep
///
/// The obvious cheap-to-write version — let the dictionary grow past capacity, then sort by last
/// use and drop the oldest quarter — was measured at 12 to 17 frames per 900 over the 8.3 ms
/// budget on a fling. The sort is O(n log n) over four thousand string keys and it lands inside
/// one unlucky frame every twenty-odd. A p99 is exactly the statistic that notices.
///
/// So this is a real least-recently-used cache: a fixed array of nodes threaded into a doubly
/// linked list by index, with the dictionary mapping key to slot. Every operation is O(1), the
/// node array never grows past ``capacity``, and eviction reuses the tail's slot rather than
/// allocating. No frame pays for another frame's insertions.
///
/// The colour is deliberately **not** part of the key. Lines carry no foreground-colour
/// attribute, so `CTLineDraw` paints them in the context's current fill colour — which means one
/// shaped line serves the same string in body text, in error red, and under a selection.
@MainActor
public final class TextLayoutCache {
    /// Text plus font. Not colour — see the class note.
    public struct Key: Hashable, Sendable {
        public var text: String
        public var font: FontKey

        public init(text: String, font: FontKey) {
            self.text = text
            self.font = font
        }
    }

    private var storage: BoundedLRU<Key, ShapedLine>

    /// How many lines the cache holds before it evicts. 4,096 covers several screens of a dense
    /// sheet, which is enough that a fling never re-shapes what it drew a moment ago.
    public var capacity: Int { storage.capacity }

    public init(capacity: Int = 4096) {
        storage = BoundedLRU(capacity: max(16, capacity))
    }

    /// Lines currently held. Never exceeds ``capacity``.
    public var count: Int { storage.count }

    /// The shaped line for this text and font, shaping it only if it is not already here.
    public func shaped(_ text: String, font key: FontKey) -> ShapedLine {
        var hit = false
        let line = storage.value(for: Key(text: text, font: key), hit: &hit) {
            Self.shape(text, font: FontResolver.font(for: key))
        }
        // A ternary would try to consume the atomic, which is noncopyable.
        if hit {
            GridInstrumentation.count(GridInstrumentation.textCacheHits)
        } else {
            GridInstrumentation.count(GridInstrumentation.textShapes)
        }
        return line
    }

    /// The width `text` would occupy.
    public func width(of text: String, font key: FontKey) -> Double {
        shaped(text, font: key).width
    }

    /// Empties the cache.
    public func removeAll() {
        storage.removeAll()
    }

    static func shape(_ text: String, font: CTFont) -> ShapedLine {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ShapedLine(line: line, width: width, ascent: ascent, descent: descent, leading: leading)
    }
}

/// A bounded cache of wrapped paragraphs, for cells with `wrapText` on.
///
/// Separate from ``TextLayoutCache`` because a wrapped cell's layout depends on the column width,
/// so the key carries it — and because a sheet has far fewer wrapped cells than plain ones, so
/// giving them their own smaller budget stops one wrapped column from evicting everything else.
@MainActor
public final class WrappedTextCache {
    public struct Key: Hashable, Sendable {
        public var text: String
        public var font: FontKey
        /// Quantised to whole points, so a 0.3pt column-resize step does not invalidate.
        public var width: Int

        public init(text: String, font: FontKey, width: Double) {
            self.text = text
            self.font = font
            self.width = Int(width.rounded())
        }
    }

    private struct Entry {
        var lines: [ShapedLine]
        var lastUsed: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(8, capacity)
    }

    public var count: Int { entries.count }

    /// The wrapped lines for this text at this width.
    public func lines(_ text: String, font key: FontKey, width: Double) -> [ShapedLine] {
        let cacheKey = Key(text: text, font: key, width: width)
        clock &+= 1
        if var existing = entries[cacheKey] {
            existing.lastUsed = clock
            entries[cacheKey] = existing
            GridInstrumentation.count(GridInstrumentation.textCacheHits)
            return existing.lines
        }
        let built = Self.wrap(text, font: FontResolver.font(for: key), width: width)
        GridInstrumentation.count(GridInstrumentation.textShapes, built.count)
        entries[cacheKey] = Entry(lines: built, lastUsed: clock)
        if entries.count > capacity {
            let target = entries.count - (capacity * 3) / 4
            let doomed = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(target).map(\.key)
            for key in doomed { entries.removeValue(forKey: key) }
        }
        return built
    }

    public func removeAll() { entries.removeAll(keepingCapacity: true) }

    private static func wrap(_ text: String, font: CTFont, width: Double) -> [ShapedLine] {
        guard width > 1, !text.isEmpty else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var result: [ShapedLine] = []
        var start = 0
        let length = attributed.length
        // A hard ceiling: a cell with 32,767 characters in a 20pt column would otherwise produce
        // thousands of lines nobody can see. Excel clips too.
        while start < length, result.count < 256 {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, width)
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            result.append(
                ShapedLine(line: line, width: lineWidth, ascent: ascent, descent: descent, leading: leading)
            )
            start += count
        }
        return result
    }
}
