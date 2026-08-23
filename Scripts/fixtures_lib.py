#!/usr/bin/env python3
"""Shared helpers for gen-fixtures.py.

Kept separate so the fixture *recipes* in gen-fixtures.py stay readable. Nothing
in here is shipped — this is build-time dev tooling for the golden corpus.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import warnings
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Fixtures")
SOFFICE = "/Applications/LibreOffice.app/Contents/MacOS/soffice"

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKGREL = "http://schemas.openxmlformats.org/package/2006/relationships"
NS_CT = "http://schemas.openxmlformats.org/package/2006/content-types"
RT = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

XMLDECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'


# --------------------------------------------------------------------------
# paths / io
# --------------------------------------------------------------------------

def fx(relpath: str) -> str:
    p = os.path.join(FIXTURES, relpath)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def write_bytes(relpath: str, data: bytes) -> str:
    p = fx(relpath)
    with open(p, "wb") as f:
        f.write(data)
    return p


def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False, sort_keys=False)
        f.write("\n")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# sidecar authoring
# --------------------------------------------------------------------------

def cell(kind: str, value, formula=None, fmt="General", flags=None):
    """One entry of a sheet's `cells` map in a `.expected.json` sidecar.

    `kind` is the SheetModel.CellValue case name: number | text | boolean |
    error | empty. `fmt` is the *resolved* OOXML number-format string (built-in
    ids resolved to their implicit format code), not the numFmtId.
    """
    d = {"type": kind, "value": value}
    if formula is not None:
        d["formula"] = formula
    d["numberFormat"] = fmt
    if flags:
        d["flags"] = flags
    return d


def sheet(name, cells, index=0, visibility="visible", dimension=None,
          used_range=None, merges=None, frozen=None, split=None,
          col_widths=None, row_heights=None, **extra):
    d = {
        "name": name,
        "index": index,
        "visibility": visibility,
        "dimension": dimension,
        "usedRange": used_range,
        "cells": cells,
    }
    if merges is not None:
        d["merges"] = merges
    if frozen is not None:
        d["frozen"] = frozen
    if split is not None:
        d["split"] = split
    if col_widths is not None:
        d["columnWidths"] = col_widths
    if row_heights is not None:
        d["rowHeights"] = row_heights
    d.update(extra)
    return d


def emit_sidecar(relpath: str, proves: str, sheets, *, verified_by,
                 date_system=1900, defined_names=None, passthrough=None,
                 skip_checks=None, **extra):
    """Write `<fixture>.expected.json` next to the fixture."""
    path = fx(relpath) + ".expected.json"
    doc = {
        "file": relpath.replace(os.sep, "/"),
        "kind": "xlsx",
        "proves": proves,
        "valuesVerifiedBy": verified_by,
        "dateSystem": date_system,
        "sheets": sheets,
    }
    if defined_names is not None:
        doc["definedNames"] = defined_names
    if passthrough is not None:
        doc["passthroughEntries"] = passthrough
    if skip_checks:
        doc["skipChecks"] = skip_checks
    doc.update(extra)
    write_json(path, doc)
    return path


def emit_csv_sidecar(relpath: str, proves: str, *, delimiter, quote, line_ending,
                     encoding, bom, rows, ragged=False, **extra):
    path = fx(relpath) + ".expected.json"
    doc = {
        "file": relpath.replace(os.sep, "/"),
        "kind": "csv",
        "proves": proves,
        "valuesVerifiedBy": "byte-level authoring (the fixture IS the expectation)",
        "dialect": {
            "delimiter": delimiter,
            "quote": quote,
            "lineEnding": line_ending,
            "encoding": encoding,
            "bom": bom,
        },
        "rowCount": len(rows),
        "maxColumns": max((len(r) for r in rows), default=0),
        "ragged": ragged,
        "rows": rows,
    }
    doc.update(extra)
    write_json(path, doc)
    return path


def attach_passthrough_hashes(relpath: str, must_survive) -> None:
    """Record sha256 of every ZIP entry, and flag the ones A2 must not touch."""
    path = fx(relpath)
    side = path + ".expected.json"
    with open(side, encoding="utf-8") as f:
        doc = json.load(f)
    entries = {}
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            entries[info.filename] = {
                "sha256": hashlib.sha256(z.read(info.filename)).hexdigest(),
                "crc32": info.CRC,
                "uncompressedSize": info.file_size,
                "method": info.compress_type,
            }
    doc["zipEntries"] = entries
    doc["passthroughEntries"] = sorted(must_survive)
    doc["passthroughContract"] = (
        "After read -> modify one cell of the first sheet -> write, every entry "
        "listed in passthroughEntries must be byte-identical to the original "
        "(compare inflated bytes AND crc32). Only xl/worksheets/sheet1.xml, "
        "xl/sharedStrings.xml and xl/calcChain.xml are allowed to differ."
    )
    write_json(side, doc)


# --------------------------------------------------------------------------
# raw xlsx construction (full byte control)
# --------------------------------------------------------------------------

MINIMAL_STYLES = (
    XMLDECL
    + f'<styleSheet xmlns="{NS_MAIN}">'
    '<numFmts count="0"/>'
    '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    "</styleSheet>"
)


def root_rels() -> str:
    return (XMLDECL + f'<Relationships xmlns="{NS_PKGREL}">'
            f'<Relationship Id="rId1" Type="{RT}/officeDocument" Target="xl/workbook.xml"/>'
            "</Relationships>")


def workbook_xml(sheets, extra_head="", defined_names="", date1904=False) -> str:
    pr = '<workbookPr date1904="1"/>' if date1904 else ""
    items = "".join(
        f'<sheet name="{n}" sheetId="{i+1}" r:id="rId{i+1}"'
        + (f' state="{st}"' if st != "visible" else "")
        + "/>"
        for i, (n, st) in enumerate(sheets)
    )
    return (XMLDECL + f'<workbook xmlns="{NS_MAIN}" xmlns:r="{NS_R}">'
            + pr + extra_head + f"<sheets>{items}</sheets>" + defined_names
            + "</workbook>")


def workbook_rels(n_sheets, extra="") -> str:
    rels = "".join(
        f'<Relationship Id="rId{i+1}" Type="{RT}/worksheet" Target="worksheets/sheet{i+1}.xml"/>'
        for i in range(n_sheets)
    )
    rels += f'<Relationship Id="rIdStyles" Type="{RT}/styles" Target="styles.xml"/>'
    rels += f'<Relationship Id="rIdSst" Type="{RT}/sharedStrings" Target="sharedStrings.xml"/>'
    return XMLDECL + f'<Relationships xmlns="{NS_PKGREL}">' + rels + extra + "</Relationships>"


def content_types(n_sheets, extra="") -> str:
    ov = "".join(
        f'<Override PartName="/xl/worksheets/sheet{i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        for i in range(n_sheets)
    )
    return (XMLDECL + f'<Types xmlns="{NS_CT}">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            + ov +
            '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
            '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
            + extra + "</Types>")


def shared_strings(items) -> str:
    si = "".join(f"<si><t>{x}</t></si>" for x in items)
    return (XMLDECL + f'<sst xmlns="{NS_MAIN}" count="{len(items)}" '
            f'uniqueCount="{len(items)}">' + si + "</sst>")


def worksheet_xml(body, dimension=None, views="", cols="", merges="", tail="") -> str:
    dim = f'<dimension ref="{dimension}"/>' if dimension else ""
    return (XMLDECL + f'<worksheet xmlns="{NS_MAIN}" xmlns:r="{NS_R}">'
            + dim + views + cols + f"<sheetData>{body}</sheetData>" + merges + tail
            + "</worksheet>")


def base_parts(sheet_bodies, sheet_names=None, sst=None, date1904=False,
               defined_names="", styles=None):
    """A complete, minimal, *valid* xlsx as an ordered dict of part -> str."""
    n = len(sheet_bodies)
    names = sheet_names or [("Sheet1", "visible")] if n == 1 else (
        sheet_names or [(f"Sheet{i+1}", "visible") for i in range(n)])
    parts = {
        "[Content_Types].xml": content_types(n),
        "_rels/.rels": root_rels(),
        "xl/workbook.xml": workbook_xml(names, defined_names=defined_names, date1904=date1904),
        "xl/_rels/workbook.xml.rels": workbook_rels(n),
        "xl/styles.xml": styles or MINIMAL_STYLES,
        "xl/sharedStrings.xml": shared_strings(sst or []),
    }
    for i, b in enumerate(sheet_bodies):
        parts[f"xl/worksheets/sheet{i+1}.xml"] = b
    return parts


def zip_parts(relpath: str, parts, compress=zipfile.ZIP_DEFLATED) -> str:
    p = fx(relpath)
    with zipfile.ZipFile(p, "w", compress) as z:
        for name, data in parts.items():
            if isinstance(data, str):
                data = data.encode("utf-8")
            zi = zipfile.ZipInfo(name, date_time=(2024, 1, 1, 0, 0, 0))
            zi.compress_type = compress
            zi.external_attr = 0o600 << 16
            z.writestr(zi, data)
    return p


# --------------------------------------------------------------------------
# raw zip surgery (hostile fixtures)
# --------------------------------------------------------------------------

def raw_zip(relpath: str, entries, compress=True) -> str:
    """Assemble a zip by hand so entry names, sizes and CRCs can lie.

    entries: list of dicts with keys
        name (str), data (bytes),
        optional: declared_uncompressed, declared_compressed, crc, method,
                  zip64 (bool), compress (bool)
    """
    p = fx(relpath)
    out = bytearray()
    central = bytearray()
    count = 0
    for e in entries:
        name = e["name"].encode("utf-8")
        data = e["data"]
        method = e.get("method", 8 if e.get("compress", compress) else 0)
        if method == 8:
            co = zlib.compressobj(9, zlib.DEFLATED, -15)
            blob = co.compress(data) + co.flush()
        else:
            blob = data
        crc = e.get("crc", zlib.crc32(data) & 0xFFFFFFFF)
        usize = e.get("declared_uncompressed", len(data))
        csize = e.get("declared_compressed", len(blob))
        offset = len(out)

        if e.get("zip64"):
            lo_u, lo_c = 0xFFFFFFFF, 0xFFFFFFFF
            extra = struct.pack("<HHQQ", 0x0001, 16, usize, csize)
        else:
            lo_u, lo_c = usize & 0xFFFFFFFF, csize & 0xFFFFFFFF
            extra = b""

        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 45 if extra else 20, 0,
                           method, 0, 0x21, crc, lo_c, lo_u, len(name), len(extra))
        out += name + extra + blob

        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 45, 45 if extra else 20, 0,
                               method, 0, 0x21, crc, lo_c, lo_u, len(name), len(extra),
                               0, 0, 0, 0, offset)
        central += name + extra
        count += 1

    cd_off = len(out)
    out += central
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, count, count,
                       len(central), cd_off, 0)
    with open(p, "wb") as f:
        f.write(bytes(out))
    return p


# --------------------------------------------------------------------------
# LibreOffice recalculation (independent ground truth)
# --------------------------------------------------------------------------

_LO_VERSION = None


def soffice_available() -> bool:
    return os.path.exists(SOFFICE)


def soffice_version() -> str:
    global _LO_VERSION
    if _LO_VERSION is None:
        try:
            r = subprocess.run([SOFFICE, "--version"], capture_output=True,
                               text=True, timeout=120)
            _LO_VERSION = (r.stdout or r.stderr).strip().splitlines()[-1]
        except Exception:
            _LO_VERSION = "LibreOffice (version unknown)"
    return _LO_VERSION


def recalc(path: str) -> None:
    """Load in LibreOffice Calc and re-save, so every <f> gains a real <v>.

    The fixtures are written with openpyxl, which stores formulas with **no**
    cached value. LibreOffice therefore has to actually evaluate them to render
    the sheet, and writes the results back on save. That makes the cached values
    in `formulas/` ground truth produced by a real spreadsheet engine rather than
    by whoever wrote the sidecar.
    """
    if not soffice_available():
        raise SystemExit("LibreOffice not found; formulas/ needs it for ground truth")
    with tempfile.TemporaryDirectory() as td:
        profile = os.path.join(td, "profile")
        outdir = os.path.join(td, "out")
        os.makedirs(outdir, exist_ok=True)
        r = subprocess.run(
            [SOFFICE, "--headless", "--norestore", "--invisible",
             f"-env:UserInstallation=file://{profile}",
             "--convert-to", "xlsx", "--outdir", outdir, path],
            capture_output=True, text=True, timeout=600)
        produced = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + ".xlsx")
        if not os.path.exists(produced):
            raise SystemExit(f"LibreOffice failed on {path}:\n{r.stdout}\n{r.stderr}")
        shutil.move(produced, path)


def openpyxl_save(wb, relpath: str) -> str:
    p = fx(relpath)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        wb.save(p)
    return p


def tiny_png() -> bytes:
    """A 4x4 solid PNG built by hand — no Pillow dependency."""
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))
    w = h = 4
    raw = b"".join(b"\x00" + bytes([0x2E, 0x6E, 0xF0] * w) for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def fake_vba_project() -> bytes:
    """A structurally-recognisable OLE2/CFB container standing in for a real
    vbaProject.bin. It is NEVER executed — OpenSheets refuses to run VBA by
    design (PLAN.md 7.3) — it exists only to prove the bytes survive a save."""
    SECTOR = 512
    hdr = bytearray(SECTOR)
    hdr[0:8] = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"      # CFB magic
    hdr[24:26] = struct.pack("<H", 0x003E)               # minor version
    hdr[26:28] = struct.pack("<H", 0x0003)               # major version
    hdr[28:30] = struct.pack("<H", 0xFFFE)               # little endian
    hdr[30:32] = struct.pack("<H", 9)                    # sector shift (512)
    hdr[32:34] = struct.pack("<H", 6)                    # mini sector shift
    hdr[44:48] = struct.pack("<I", 1)                    # # FAT sectors
    hdr[48:52] = struct.pack("<I", 1)                    # first dir sector
    hdr[56:60] = struct.pack("<I", 4096)                 # mini stream cutoff
    hdr[60:64] = struct.pack("<I", 0xFFFFFFFE)           # first mini FAT
    hdr[68:72] = struct.pack("<I", 0xFFFFFFFE)           # first DIFAT
    hdr[76:80] = struct.pack("<I", 0)                    # DIFAT[0] -> sector 0
    for i in range(1, 109):
        hdr[76 + i * 4: 80 + i * 4] = struct.pack("<I", 0xFFFFFFFF)

    fat = bytearray(b"\xff" * SECTOR)
    fat[0:4] = struct.pack("<I", 0xFFFFFFFD)             # FAT sector
    fat[4:8] = struct.pack("<I", 0xFFFFFFFE)             # dir chain end

    def dirent(name, kind, child=0xFFFFFFFF, left=0xFFFFFFFF, right=0xFFFFFFFF):
        e = bytearray(128)
        nb = name.encode("utf-16-le") + b"\x00\x00"
        e[0:len(nb)] = nb
        e[64:66] = struct.pack("<H", len(nb))
        e[66] = kind                                     # 1 storage, 2 stream, 5 root
        e[67] = 1                                        # black
        e[68:72] = struct.pack("<I", left)
        e[72:76] = struct.pack("<I", right)
        e[76:80] = struct.pack("<I", child)
        e[116:120] = struct.pack("<I", 0xFFFFFFFE)
        return bytes(e)

    directory = (dirent("Root Entry", 5, child=1)
                 + dirent("VBA", 1, child=2)
                 + dirent("dir", 2)
                 + dirent("_VBA_PROJECT", 2))
    directory += b"\x00" * (SECTOR - len(directory) % SECTOR)
    return bytes(hdr) + bytes(fat) + directory
