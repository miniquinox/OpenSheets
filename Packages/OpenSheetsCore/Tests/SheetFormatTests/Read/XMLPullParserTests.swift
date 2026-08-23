//
//  XMLPullParserTests.swift
//  SheetFormatTests
//
//  A1. The hardened XML reader, on its own.
//

import Foundation
import Testing

import SheetFormat
import SheetModel
import TestSupport

@Suite("hardened XML pull parser")
struct XMLPullParserTests {
    private func parse<Result>(
        _ xml: String,
        _ body: (inout XMLPullParser) throws(SheetError) -> Result
    ) throws -> Result {
        try XMLParsing.withParser(over: Array(xml.utf8), part: "test.xml", body)
    }

    /// Collects `(event, localName)` for a whole document.
    private func events(_ xml: String) throws -> [(XMLPullParser.Event, String)] {
        try parse(xml) { parser throws(SheetError) in
            var collected: [(XMLPullParser.Event, String)] = []
            while let event = try parser.next() {
                collected.append((event, event == .characters ? (try parser.text.string()) : parser.name))
            }
            return collected
        }
    }

    // MARK: - Shape

    @Test("a self-closing tag produces a matching end event, so depth tracking is uniform")
    func selfClosingTagsAreBalanced() throws {
        let collected = try events("<a><b/><c>x</c></a>")
        #expect(collected.map(\.0) == [
            .startElement, .startElement, .endElement, .startElement, .characters, .endElement, .endElement,
        ])
        #expect(collected.map(\.1) == ["a", "b", "b", "c", "x", "c", "a"])
    }

    @Test("prefixes are ignored; the local name is what matches")
    func matchesOnLocalName() throws {
        try parse("<x:worksheet xmlns:x='urn:x' x:attr='7'><x:c r='A1'/></x:worksheet>") { parser throws(SheetError) in
            _ = try parser.next()
            #expect(parser.nameIs("worksheet"))
            #expect(parser.qualifiedName == "x:worksheet")
            #expect(parser.attribute("attr")?.int == 7)
            _ = try parser.next()
            #expect(parser.nameIs("c"))
            #expect(parser.attribute("r")?.cellRef == CellRef(row: 0, column: 0))
        }
    }

    @Test("the XML declaration, comments and processing instructions are skipped")
    func skipsPrologue() throws {
        let collected = try events(
            "<?xml version='1.0'?><!-- a comment with <angle> brackets --><?pi data?><a/>"
        )
        #expect(collected.map(\.1) == ["a", "a"])
    }

    @Test("CDATA arrives as text with no entity resolution")
    func readsCDATA() throws {
        let collected = try events("<a><![CDATA[1 < 2 && x=\"&amp;\"]]></a>")
        #expect(collected.contains { $0.1 == "1 < 2 && x=\"&amp;\"" })
    }

    // MARK: - Text

    @Test("the five built-in entities and numeric references decode")
    func decodesEntities() throws {
        let collected = try events("<a>&lt;&amp;&gt;&quot;&apos;&#65;&#x42;</a>")
        #expect(collected.first { $0.0 == .characters }?.1 == "<&>\"'AB")
    }

    @Test("an entity nothing defines is a parse error, not a silent drop")
    func rejectsUndefinedEntities() {
        expectThrows(code: "xml.malformed") { try events("<a>&lol9;</a>") }
    }

    @Test("whitespace is never trimmed, because xml:space=\"preserve\" means it is data")
    func preservesWhitespace() throws {
        let collected = try events("<t xml:space='preserve'>  spaced  </t>")
        #expect(collected.first { $0.0 == .characters }?.1 == "  spaced  ")
    }

    @Test("a control character XML 1.0 forbids is refused")
    func rejectsIllegalCharacters() {
        expectThrows(code: "xml.invalidEncoding") { try events("<t>before\u{0}after</t>") }
        expectThrows(code: "xml.invalidEncoding") { try events("<t>bell\u{7}and\u{B}vtab</t>") }
    }

    @Test("a numeric reference naming an illegal character is refused")
    func rejectsIllegalNumericReferences() {
        expectThrows(code: "xml.invalidEncoding") { try events("<t>&#0;</t>") }
    }

    @Test("OOXML's _xHHHH_ escapes decode, and an illegal result is dropped rather than reinserted")
    func decodesOOXMLEscapes() throws {
        try parse("<t>line_x000A_break</t>") { parser throws(SheetError) in
            _ = try parser.next()
            _ = try parser.next()
            #expect(try parser.text.cellText() == "line\nbreak")
        }
        try parse("<t>escaped _x0000_ form</t>") { parser throws(SheetError) in
            _ = try parser.next()
            _ = try parser.next()
            #expect(try parser.text.cellText() == "escaped  form")
        }
        try parse("<t>_x005F_x0041_</t>") { parser throws(SheetError) in
            _ = try parser.next()
            _ = try parser.next()
            #expect(try parser.text.cellText() == "_x0041_", "an escaped underscore must not start an escape")
        }
    }

    // MARK: - Hardening

    @Test("any DOCTYPE is refused, however harmless")
    func refusesEveryDoctype() {
        expectThrows(code: "xml.doctype") { try events("<!DOCTYPE a SYSTEM 'a.dtd'><a/>") }
        expectThrows(code: "xml.doctype") { try events("<!DOCTYPE a><a/>") }
        expectThrows(code: "xml.doctype") {
            try events("<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>")
        }
    }

    @Test("nesting past the depth cap is refused before the stack is")
    func refusesDeepNesting() {
        let deep = String(repeating: "<a>", count: Limits.maxXMLDepth + 20)
        expectThrows(code: "xml.depth") { try events(deep) }
    }

    @Test("an element with too many attributes is refused")
    func refusesAttributeFloods() {
        let attributes = (0 ..< (Limits.maxXMLAttributesPerElement + 5))
            .map { "a\($0)='1'" }
            .joined(separator: " ")
        expectThrows(code: "xml.attributeCount") { try events("<a \(attributes)/>") }
    }

    @Test("mismatched and unclosed elements are refused, and the message says which")
    func refusesMalformedNesting() throws {
        expectThrows(code: "xml.malformed") { try events("<a><b></a></b>") }
        expectThrows(code: "xml.malformed") { try events("<a><b>") }
        expectThrows(code: "xml.malformed") { try events("</a>") }

        do {
            _ = try events("<worksheet><sheetData><row><c><v>1</v></row></sheetData></worksheet>")
            Issue.record("mismatched nesting parsed")
        } catch let error as SheetError {
            #expect("\(error)".contains("test.xml"), "the message must name the part: \(error)")
            #expect("\(error)".contains("</row>"), "the message must say what went wrong: \(error)")
        }
    }

    // MARK: - Verbatim capture

    @Test("skipElement returns the element exactly as written")
    func capturesVerbatim() throws {
        let source = """
        <worksheet><sheetData/><x:conditionalFormatting  sqref="B2:C8" \
        xmlns:x="urn:x"><x:cfRule type='cellIs'><formula>100</formula></x:cfRule>\
        </x:conditionalFormatting><drawing r:id="rId1"/></worksheet>
        """
        let captured = try XMLParsing.withParser(over: Array(source.utf8), part: "sheet1.xml") {
            parser throws(SheetError) in
            var result: [(String, String)] = []
            while let event = try parser.next() {
                guard event == .startElement, parser.depth == 2 else { continue }
                let name = parser.name
                let range = try parser.skipElement()
                result.append((name, parser.rawText(range)))
            }
            return result
        }
        #expect(captured.map(\.0) == ["sheetData", "conditionalFormatting", "drawing"])
        // Original prefix, original attribute order, original double space, no re-escaping.
        #expect(
            captured[1].1 == """
            <x:conditionalFormatting  sqref="B2:C8" xmlns:x="urn:x">\
            <x:cfRule type='cellIs'><formula>100</formula></x:cfRule></x:conditionalFormatting>
            """
        )
        #expect(captured[2].1 == "<drawing r:id=\"rId1\"/>")
        for (_, xml) in captured {
            #expect(source.contains(xml), "a captured fragment is not a substring of the source")
        }
    }

    // MARK: - Value conversions

    @Test("numbers survive OOXML's spelling of them")
    func parsesNumbers() throws {
        for (text, expected) in [
            ("42", 42.0), ("-0.0000001", -1e-7), ("0", 0),
            ("1.7976931348623157E+308", .greatestFiniteMagnitude), ("1e3", 1000),
        ] {
            try parse("<v>\(text)</v>") { parser throws(SheetError) in
                _ = try parser.next()
                _ = try parser.next()
                #expect(parser.text.double == expected, "\(text)")
            }
        }
    }

    @Test("a number with trailing junk is not a number")
    func rejectsPartialNumbers() throws {
        for text in ["42abc", "", "  ", "0x10", "--1"] {
            try parse("<v>\(text)</v>") { parser throws(SheetError) in
                _ = try parser.next()
                if try parser.next() == .characters {
                    #expect(parser.text.double == nil, "'\(text)' should not parse as a number")
                }
            }
        }
    }

    @Test("an integer wider than Int32 is read, not overflowed")
    func parsesWideIntegers() throws {
        try parse("<row r='4294967295'/>") { parser throws(SheetError) in
            _ = try parser.next()
            #expect(parser.attribute("r")?.int == 4_294_967_295)
            #expect(parser.attribute("r")?.int32 == nil, "it does not fit in Int32 and must not pretend to")
        }
    }
}

/// The byte-level reference parser must agree with the model's, exactly.
///
/// ``XMLValue/cellRef`` exists so a million cells do not each allocate a `String`, which means
/// there are two implementations of the same rules. Two implementations drift; this is what
/// stops them.
@Suite("cell reference parity")
struct CellReferenceParityTests {
    static let candidates: [String] = [
        "A1", "a1", "B7", "XFD1048576", "AA100", "Z1", "AAA1",
        // Everything `hostile/invalid-cell-reference.xlsx` contains, plus the neighbours of every
        // boundary.
        "", "A", "1", "A0", "0", "1A", "A-1", "ZZZZZ1", "XFE1", "A1048577", "$A$1", "A1B", "A 1",
        "AMJ1", "XFD1048577", "AAAA1", "A00", "A01",
    ]

    @Test("agrees with CellRef(a1:) on every candidate", arguments: candidates)
    func agrees(text: String) throws {
        let viaModel = CellRef(a1: text)
        let viaBytes = try XMLParsing.withParser(
            over: Array("<c r=\"\(text)\"/>".utf8), part: "parity"
        ) { parser throws(SheetError) in
            _ = try parser.next()
            return parser.attribute("r")?.cellRef
        }
        #expect(viaModel == viaBytes, "'\(text)': model \(String(describing: viaModel)), bytes \(String(describing: viaBytes))")
    }
}
