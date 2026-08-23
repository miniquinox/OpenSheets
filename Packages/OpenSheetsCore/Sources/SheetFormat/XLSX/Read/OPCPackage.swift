//
//  OPCPackage.swift
//  SheetFormat
//
//  A1 owns this file. `[Content_Types].xml` and the relationship graph — the only honest way to
//  find a part.
//

import Foundation

import MiniZip
import SheetModel

/// One `<Relationship>` from a `.rels` part.
public struct OPCRelationship: Sendable, Hashable {
    /// The `Id` the referring part uses — `rId3`.
    public var id: String
    /// The full relationship type URI.
    public var type: String
    /// The `Target`, exactly as written and **not** resolved.
    public var target: String
    /// Whether the target leaves the package. External targets are never fetched (PLAN.md §7.3).
    public var isExternal: Bool

    /// The last path component of ``type``, which is what actually distinguishes one
    /// relationship from another: `worksheet`, `styles`, `sharedStrings`, `hyperlink`.
    public var kind: String {
        guard let slash = type.lastIndex(of: "/") else { return type }
        return String(type[type.index(after: slash)...])
    }
}

/// The relationships declared by one part.
public struct OPCRelationships: Sendable {
    /// The relationships, in file order.
    public var items: [OPCRelationship]

    /// The directory targets are relative to — the *referring* part's directory.
    public var base: String

    public subscript(id: String) -> OPCRelationship? {
        items.first { $0.id == id }
    }

    /// Every relationship of a given kind, in file order.
    public func all(kind: String) -> [OPCRelationship] {
        items.filter { $0.kind == kind }
    }

    /// The first relationship of a given kind.
    public func first(kind: String) -> OPCRelationship? {
        items.first { $0.kind == kind }
    }

    /// The package-relative path a relationship points at, or `nil` for an external target.
    public func resolve(_ relationship: OPCRelationship) -> String? {
        guard !relationship.isExternal else { return nil }
        return OPCPackage.resolve(target: relationship.target, relativeTo: base)
    }

    /// The path for `id`, or `nil`.
    public func path(forID id: String) -> String? {
        self[id].flatMap(resolve)
    }

    /// No relationships at all.
    public static let empty = OPCRelationships(items: [], base: "")
}

/// The OPC layer: content types, relationships, and part-path arithmetic.
///
/// **Nothing here hardcodes a path.** `xl/worksheets/sheet1.xml` is a convention Excel happens to
/// follow and that Numbers, Google Sheets and half the server-side generators do not. Every part
/// is found by walking `_rels/.rels` to the workbook and then the workbook's own rels to its
/// sheets — which is also how `Scripts/validate-fixtures.py` establishes ground truth, so a
/// reader that shortcuts disagrees with the corpus by construction.
public enum OPCPackage {
    /// Where the package's root relationships live. This one path *is* fixed by the OPC spec.
    public static let rootRelationshipsPath = "_rels/.rels"

    /// Where `[Content_Types].xml` lives. Also fixed by the spec.
    public static let contentTypesPath = "[Content_Types].xml"

    // MARK: - Path arithmetic

    /// The directory containing `path`, without a trailing slash. `""` for a root-level part.
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex ..< slash])
    }

    /// The final path component of `path`.
    public static func fileName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The `.rels` part describing `path`: `xl/workbook.xml` → `xl/_rels/workbook.xml.rels`.
    public static func relationshipsPath(for path: String) -> String {
        let folder = directory(of: path)
        let name = fileName(of: path)
        return folder.isEmpty ? "_rels/\(name).rels" : "\(folder)/_rels/\(name).rels"
    }

    /// Resolves a relationship `Target` against the referring part's directory.
    ///
    /// Handles the three forms that turn up in real files: a plain relative target
    /// (`worksheets/sheet1.xml`), an absolute one (`/xl/worksheets/sheet1.xml`, which
    /// `Fixtures/basic/minimal.xlsx` uses), and one carrying `..` segments.
    public static func resolve(target: String, relativeTo base: String) -> String {
        var raw = target
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[raw.startIndex ..< hash]) }
        raw = raw.replacingOccurrences(of: "\\", with: "/")

        let combined: String = if raw.hasPrefix("/") {
            String(raw.dropFirst())
        } else if base.isEmpty {
            raw
        } else {
            "\(base)/\(raw)"
        }

        var stack: [Substring] = []
        for component in combined.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(component)
            }
        }
        return stack.joined(separator: "/")
    }

    // MARK: - Content types

    /// `[Content_Types].xml`, resolved down to "what is the content type of this part".
    public struct ContentTypes: Sendable {
        var defaults: [String: String]
        var overrides: [String: String]

        /// The content type for a part: an override first, then the extension default.
        public func type(of path: String) -> String? {
            if let exact = overrides["/" + path] { return exact }
            guard let dot = path.lastIndex(of: ".") else { return nil }
            return defaults[String(path[path.index(after: dot)...]).lowercased()]
        }

        /// Whether any part in the package declares this content type.
        public func containsType(_ type: String) -> Bool {
            overrides.values.contains(type) || defaults.values.contains(type)
        }
    }

    /// Parses `[Content_Types].xml`.
    public static func readContentTypes(_ archive: ZipArchive) throws(SheetError) -> ContentTypes {
        guard let bytes = try archive.bytesIfPresent(of: contentTypesPath) else {
            throw SheetError.criticalPartMissing(path: contentTypesPath)
        }
        return try XMLParsing.withParser(over: bytes, part: contentTypesPath) { parser throws(SheetError) in
            var defaults: [String: String] = [:]
            var overrides: [String: String] = [:]
            while let event = try parser.next() {
                guard event == .startElement else { continue }
                if parser.nameIs("Default"),
                   let ext = parser.attribute("Extension"), let type = parser.attribute("ContentType") {
                    let key = try ext.string().lowercased()
                    defaults[key] = try type.string()
                } else if parser.nameIs("Override"),
                          let name = parser.attribute("PartName"), let type = parser.attribute("ContentType") {
                    let key = try name.string()
                    overrides[key] = try type.string()
                }
            }
            return ContentTypes(defaults: defaults, overrides: overrides)
        }
    }

    // MARK: - Relationships

    /// Parses the `.rels` part describing `partPath`.
    ///
    /// A part with no rels is normal, not an error, so this returns an empty set rather than
    /// throwing. Pass ``rootRelationshipsPath`` for the package's own relationships.
    public static func readRelationships(
        for partPath: String,
        in archive: ZipArchive
    ) throws(SheetError) -> OPCRelationships {
        let isRoot = partPath == rootRelationshipsPath
        let relsPath = isRoot ? partPath : relationshipsPath(for: partPath)
        let base = isRoot ? "" : directory(of: partPath)
        guard let bytes = try archive.bytesIfPresent(of: relsPath) else {
            return OPCRelationships(items: [], base: base)
        }
        return try XMLParsing.withParser(over: bytes, part: relsPath) { parser throws(SheetError) in
            var items: [OPCRelationship] = []
            while let event = try parser.next() {
                guard event == .startElement, parser.nameIs("Relationship") else { continue }
                guard let id = parser.attribute("Id"),
                      let type = parser.attribute("Type"),
                      let target = parser.attribute("Target")
                else { continue }
                items.append(
                    OPCRelationship(
                        id: try id.string(),
                        type: try type.string(),
                        target: try target.string(),
                        isExternal: parser.attribute("TargetMode")?.equals("External") ?? false
                    )
                )
            }
            return OPCRelationships(items: items, base: base)
        }
    }
}
