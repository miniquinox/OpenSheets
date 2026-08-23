import Foundation
@testable import SheetModel
import Testing

@Suite("ZipEntry and OpaqueParts")
struct PassthroughTests {
    private func entry(_ path: String, bytes: [UInt8] = [1, 2, 3]) -> ZipEntry {
        ZipEntry(
            path: path,
            compressedData: Data(bytes),
            compressionMethod: .deflate,
            crc32: 0xDEAD_BEEF,
            uncompressedSize: 100,
            lastModified: DOSTimestamp(date: 0x5678, time: 0x1234),
            generalPurposeFlags: 0x0008,
            externalAttributes: 0x81A4_0000,
            extraFieldLocal: Data([0x55, 0x54, 0x05, 0x00]),
            extraFieldCentral: Data([0x55, 0x54, 0x01, 0x00])
        )
    }

    @Test("compression methods map to and from their wire numbers")
    func compressionMethods() {
        #expect(CompressionMethod.store.rawValue == 0)
        #expect(CompressionMethod.deflate.rawValue == 8)
        #expect(CompressionMethod(rawValue: 0) == .store)
        #expect(CompressionMethod(rawValue: 8) == .deflate)
        #expect(CompressionMethod(rawValue: 12) == .other(12))
        #expect(CompressionMethod.store.isSupported)
        #expect(CompressionMethod.deflate.isSupported)
        #expect(!CompressionMethod.other(12).isSupported)
    }

    @Test("DOS timestamps round-trip through their packed fields")
    func dosTimestamps() {
        let components = DateTimeComponents(year: 2023, month: 3, day: 15, hour: 14, minute: 30, second: 44)
        let stamp = DOSTimestamp(components: components)
        let decoded = stamp.components
        #expect(decoded.year == 2023)
        #expect(decoded.month == 3)
        #expect(decoded.day == 15)
        #expect(decoded.hour == 14)
        #expect(decoded.minute == 30)
        #expect(decoded.second == 44, "two-second resolution keeps an even value intact")

        // Odd seconds round down, because the format cannot express them.
        let odd = DOSTimestamp(components: DateTimeComponents(year: 2023, month: 1, day: 1, second: 45))
        #expect(odd.components.second == 44)

        // Dates before 1980 clamp rather than wrapping into nonsense.
        let ancient = DOSTimestamp(components: DateTimeComponents(year: 1970, month: 6, day: 1))
        #expect(ancient.components.year == 1980)
        #expect(DOSTimestamp.epoch.components.year == 1980)
    }

    @Test("an entry keeps everything a byte-identical re-emit needs")
    func entryFidelity() {
        let original = entry("xl/charts/chart1.xml")
        #expect(original.path == "xl/charts/chart1.xml")
        #expect(original.compressedData == Data([1, 2, 3]))
        #expect(original.compressedSize == 3, "the size defaults to the payload length")
        #expect(original.crc32 == 0xDEAD_BEEF)
        #expect(original.uncompressedSize == 100)
        #expect(
            original.extraFieldLocal != original.extraFieldCentral,
            "the two extra fields are stored separately because real archives differ"
        )
        #expect(original.generalPurposeFlags == 0x0008, "bit 3 — sizes follow in a data descriptor")
        #expect(original.externalAttributes == 0x81A4_0000, "the Unix mode survives")
        #expect(original.versionMadeBy != 0)
    }

    @Test("directory entries are recognised both ways")
    func directoryDetection() {
        #expect(ZipEntry(path: "xl/media/", compressedData: Data()).isDirectory)
        #expect(!ZipEntry(path: "xl/media/image1.png", compressedData: Data()).isDirectory)
        #expect(ZipEntry(path: "d", compressedData: Data(), externalAttributes: 0x0010).isDirectory)
    }

    @Test("the claimed ratio is what catches a zip bomb")
    func compressionRatio() {
        let bomb = ZipEntry(
            path: "bomb.xml", compressedData: Data(repeating: 0, count: 1000),
            compressedSize: 1000, uncompressedSize: 1_000_000_000
        )
        #expect(bomb.claimedCompressionRatio == 1_000_000)
        #expect(bomb.claimedCompressionRatio > Limits.maxCompressionRatio)

        let normal = ZipEntry(
            path: "sheet1.xml", compressedData: Data(repeating: 0, count: 1000),
            compressedSize: 1000, uncompressedSize: 10_000
        )
        #expect(normal.claimedCompressionRatio == 10)
        #expect(normal.claimedCompressionRatio < Limits.maxCompressionRatio)
    }

    // MARK: - OpaqueParts

    @Test("parts preserve archive order and answer by path")
    func ordering() {
        let parts = OpaqueParts(entries: [
            entry("[Content_Types].xml"),
            entry("_rels/.rels"),
            entry("xl/workbook.xml"),
            entry("xl/charts/chart1.xml"),
        ])
        #expect(parts.count == 4)
        #expect(parts.paths == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/charts/chart1.xml"])
        #expect(parts["xl/workbook.xml"] != nil)
        #expect(parts["nope"] == nil)
        #expect(parts.contains("_rels/.rels"))
        #expect(!parts.isEmpty)
        #expect(OpaqueParts.empty.isEmpty)
    }

    @Test("passthroughPaths is everything we did not model — the set that must survive a save")
    func passthroughSet() {
        var parts = OpaqueParts(entries: [
            entry("xl/workbook.xml"),
            entry("xl/worksheets/sheet1.xml"),
            entry("xl/charts/chart1.xml"),
            entry("xl/vbaProject.bin"),
        ])
        parts.markModelled("xl/workbook.xml")
        parts.markModelled("xl/worksheets/sheet1.xml")

        #expect(parts.passthroughPaths == ["xl/charts/chart1.xml", "xl/vbaProject.bin"])
        #expect(parts.modelled.count == 2)
    }

    @Test("upsert replaces in place and appends new entries at the end")
    func upsert() {
        var parts = OpaqueParts(entries: [entry("a"), entry("b"), entry("c")])
        parts.upsert(entry("b", bytes: [9, 9, 9]))
        #expect(parts.paths == ["a", "b", "c"], "replacing must not reorder the archive")
        #expect(parts["b"]?.compressedData == Data([9, 9, 9]))

        parts.upsert(entry("d"))
        #expect(parts.paths == ["a", "b", "c", "d"])
    }

    @Test("removing calcChain keeps the rest addressable")
    func removal() {
        var parts = OpaqueParts(entries: [
            entry("a"), entry(OOXMLPart.calcChain), entry("c"), entry("d"),
        ])
        let removed = parts.remove(path: OOXMLPart.calcChain)
        #expect(removed != nil)
        #expect(parts.paths == ["a", "c", "d"])
        // The index must have been repaired, or later lookups silently return the wrong entry.
        #expect(parts["c"]?.path == "c")
        #expect(parts["d"]?.path == "d")
        #expect(parts[OOXMLPart.calcChain] == nil)
        #expect(parts.remove(path: "nope") == nil)
    }

    @Test("total compressed bytes is roughly the file size")
    func totalBytes() {
        let parts = OpaqueParts(entries: [entry("a"), entry("b", bytes: [1, 2, 3, 4, 5])])
        #expect(parts.totalCompressedBytes == 8)
    }

    @Test("well-known part paths are spelled once")
    func partPaths() {
        #expect(OOXMLPart.contentTypes == "[Content_Types].xml")
        #expect(OOXMLPart.rootRelationships == "_rels/.rels")
        #expect(OOXMLPart.workbook == "xl/workbook.xml")
        #expect(OOXMLPart.workbookRelationships == "xl/_rels/workbook.xml.rels")
        #expect(OOXMLPart.sharedStrings == "xl/sharedStrings.xml")
        #expect(OOXMLPart.styles == "xl/styles.xml")
        #expect(OOXMLPart.calcChain == "xl/calcChain.xml")
        #expect(OOXMLPart.vbaProject == "xl/vbaProject.bin")
        #expect(OOXMLPart.encryptedPackage == "EncryptedPackage")
        #expect(OOXMLPart.worksheet(3) == "xl/worksheets/sheet3.xml")
    }

    // MARK: - Dirty tracking

    @Test("dirty tracking is per part, so one edit does not rewrite the workbook")
    func dirtyParts() {
        var dirty = DirtyPartSet()
        #expect(dirty.isEmpty)

        dirty.mark("xl/worksheets/sheet3.xml")
        #expect(!dirty.isEmpty)
        #expect(dirty.contains("xl/worksheets/sheet3.xml"))
        #expect(!dirty.contains("xl/worksheets/sheet1.xml"))
        #expect(!dirty.contains(OOXMLPart.styles))
        #expect(!dirty.formulasChanged)

        dirty.removeAll()
        #expect(dirty.isEmpty)
    }

    @Test("marking a sheet uses its resolved part path, or flags a structure change")
    func markingSheets() {
        var dirty = DirtyPartSet()
        let known = Sheet(id: SheetID(1), name: "A", partPath: "xl/worksheets/sheetOne.xml")
        dirty.mark(sheet: known)
        #expect(dirty.contains("xl/worksheets/sheetOne.xml"))
        #expect(!dirty.partStructureChanged)

        let brandNew = Sheet(id: SheetID(2), name: "B")
        dirty.mark(sheet: brandNew)
        #expect(dirty.partStructureChanged, "a sheet with no part yet needs one allocating")
    }

    @Test("a formula change is the flag that drops calcChain")
    func formulaChangeFlag() {
        var dirty = DirtyPartSet()
        dirty.formulasChanged = true
        #expect(!dirty.isEmpty)
        #expect(DirtyPartSet.everything.formulasChanged)
        #expect(DirtyPartSet.everything.partStructureChanged)
    }
}
