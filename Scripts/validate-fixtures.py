#!/usr/bin/env python3
"""Validate the fixture corpus against its own `.expected.json` sidecars.

    python3 Scripts/validate-fixtures.py            # everything
    python3 Scripts/validate-fixtures.py formulas   # one group
    python3 Scripts/validate-fixtures.py -v         # list every check

WHY THIS EXISTS
---------------
A sidecar that merely restates what the generator wrote is worth nothing: it
proves the generator agrees with itself. So this script never imports the
generator, never uses openpyxl, and never trusts anything but the bytes on disk.
It opens each fixture as a plain ZIP, walks the relationship graph, and parses
the raw OOXML with the standard library.

For `formulas/` that gives a real cross-check. Those fixtures are written with
no cached values and then recalculated by headless LibreOffice, so the `<v>`
sitting next to each `<f>` was computed by an independent spreadsheet engine.
When this script compares the sidecar to that `<v>`, a disagreement means the
person who wrote the expectation was wrong — which is exactly the failure mode
a golden corpus is supposed to catch before six agents build on it.

Requires only the Python standard library.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Fixtures")

M = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PR = "{http://schemas.openxmlformats.org/package/2006/relationships}"

# numFmtId -> format code, for the ids Excel never writes into <numFmts>.
BUILTIN = {
    0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
    5: "$#,##0_);($#,##0)", 6: "$#,##0_);[Red]($#,##0)",
    7: "$#,##0.00_);($#,##0.00)", 8: "$#,##0.00_);[Red]($#,##0.00)",
    9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
    14: "mm-dd-yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
    18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss",
    22: "m/d/yy h:mm",
    37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)",
    39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)",
    41: '_(* #,##0_);_(* \\(#,##0\\);_(* "-"_);_(@_)',
    42: '_("$"* #,##0_);_("$"* \\(#,##0\\);_("$"* "-"_);_(@_)',
    43: '_(* #,##0.00_);_(* \\(#,##0.00\\);_(* "-"??_);_(@_)',
    44: '_("$"* #,##0.00_);_("$"* \\(#,##0.00\\);_("$"* "-"??_);_(@_)',
    45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
}

CELL_RE = re.compile(r"^([A-Z]{1,3})([0-9]{1,7})$")


def col_to_index(letters: str) -> int:
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n


def index_to_col(n: int) -> str:
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


# ---------------------------------------------------------------------------

class Report:
    def __init__(self, verbose: bool):
        self.verbose = verbose
        self.checks = 0
        self.failures: list[tuple[str, str]] = []
        self.warnings: list[tuple[str, str]] = []
        self.files = 0

    def ok(self, where: str, what: str):
        self.checks += 1
        if self.verbose:
            print(f"    ok   {where}: {what}")

    def fail(self, where: str, what: str):
        self.checks += 1
        self.failures.append((where, what))
        print(f"    FAIL {where}: {what}")

    def warn(self, where: str, what: str):
        self.warnings.append((where, what))
        print(f"    warn {where}: {what}")

    def eq(self, where, label, expected, actual, tol=None):
        if tol is not None and isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
            same = abs(expected - actual) <= max(tol, tol * abs(expected))
        else:
            same = expected == actual
        if same:
            self.ok(where, f"{label} == {expected!r}")
        else:
            self.fail(where, f"{label}: expected {expected!r}, got {actual!r}")
        return same


# ---------------------------------------------------------------------------
# an independent minimal xlsx reader
# ---------------------------------------------------------------------------

class Book:
    """Just enough OOXML to check a sidecar, resolved through the rels graph."""

    def __init__(self, path: str):
        self.z = zipfile.ZipFile(path)
        self.names = set(self.z.namelist())
        root_rels = self._rels("_rels/.rels")
        wb_target = next(t for rid, (ty, t) in root_rels.items()
                         if ty.endswith("/officeDocument"))
        self.wb_path = wb_target.lstrip("/")
        self.wb_dir = os.path.dirname(self.wb_path)
        wb = ET.fromstring(self.z.read(self.wb_path))
        wb_rels = self._rels(os.path.join(self.wb_dir, "_rels",
                                          os.path.basename(self.wb_path) + ".rels"))

        pr = wb.find(f"{M}workbookPr")
        self.date1904 = bool(pr is not None and pr.get("date1904") in ("1", "true"))

        self.sheets = []
        for el in wb.findall(f"{M}sheets/{M}sheet"):
            rid = el.get(f"{R}id")
            target = wb_rels[rid][1]
            part = (target[1:] if target.startswith("/")
                    else os.path.normpath(os.path.join(self.wb_dir, target)))
            self.sheets.append({
                "name": el.get("name"),
                "state": el.get("state", "visible"),
                "part": part.replace(os.sep, "/"),
            })

        self.defined_names = {
            dn.get("name"): (dn.text or "")
            for dn in wb.findall(f"{M}definedNames/{M}definedName")
        }

        self.sst = []
        for cand in (os.path.join(self.wb_dir, "sharedStrings.xml"),):
            if cand in self.names:
                sst = ET.fromstring(self.z.read(cand))
                for si in sst.findall(f"{M}si"):
                    self.sst.append("".join(t.text or "" for t in si.iter(f"{M}t")))
                break

        self.numfmt = {}
        styles_path = os.path.join(self.wb_dir, "styles.xml")
        if styles_path in self.names:
            st = ET.fromstring(self.z.read(styles_path))
            custom = {int(n.get("numFmtId")): n.get("formatCode")
                      for n in st.findall(f"{M}numFmts/{M}numFmt")}
            for i, xf in enumerate(st.findall(f"{M}cellXfs/{M}xf")):
                nid = int(xf.get("numFmtId", "0"))
                self.numfmt[i] = custom.get(nid, BUILTIN.get(nid, f"<unknown numFmtId {nid}>"))

    def _rels(self, path):
        path = path.replace(os.sep, "/")
        if path not in self.names:
            return {}
        el = ET.fromstring(self.z.read(path))
        return {r.get("Id"): (r.get("Type"), r.get("Target"))
                for r in el.findall(f"{PR}Relationship")}

    def sheet_xml(self, part: str):
        return ET.fromstring(self.z.read(part))

    def read_sheet(self, part: str):
        """-> (cells, dimension, merges, pane, cols, rows_meta, hyperlinks, elements)"""
        root = self.sheet_xml(part)
        dim_el = root.find(f"{M}dimension")
        dimension = dim_el.get("ref") if dim_el is not None else None

        cells = {}
        for c in root.iter(f"{M}c"):
            ref = c.get("r")
            t = c.get("t", "n")
            s = c.get("s")
            f_el = c.find(f"{M}f")
            v_el = c.find(f"{M}v")
            is_el = c.find(f"{M}is")
            formula = (f_el.text or "") if f_el is not None else None
            if f_el is not None and f_el.get("t") == "shared" and not (f_el.text or ""):
                formula = f"<shared si={f_el.get('si')}>"

            if is_el is not None:
                kind, value = "text", "".join(x.text or "" for x in is_el.iter(f"{M}t"))
            elif v_el is None:
                kind, value = "empty", None
            elif t == "s":
                idx = int(v_el.text)
                kind, value = "text", (self.sst[idx] if idx < len(self.sst) else None)
            elif t in ("str", "inlineStr"):
                kind, value = "text", (v_el.text or "")
            elif t == "b":
                kind, value = "boolean", v_el.text == "1"
            elif t == "e":
                kind, value = "error", v_el.text
            elif t == "d":
                kind, value = "text", v_el.text
            else:
                kind, value = "number", float(v_el.text)

            cells[ref] = {
                "type": kind, "value": value, "formula": formula,
                "numberFormat": self.numfmt.get(int(s) if s else 0, "General"),
            }

        merges = [m.get("ref") for m in root.findall(f"{M}mergeCells/{M}mergeCell")]
        pane_el = root.find(f"{M}sheetViews/{M}sheetView/{M}pane")
        pane = None if pane_el is None else dict(pane_el.attrib)
        cols = [dict(c.attrib) for c in root.findall(f"{M}cols/{M}col")]
        rows_meta = {r.get("r"): dict(r.attrib) for r in root.findall(f"{M}sheetData/{M}row")}
        hl = {h.get("ref"): h for h in root.findall(f"{M}hyperlinks/{M}hyperlink")}
        elements = {el.tag[len(M):] for el in root if el.tag.startswith(M)}
        return cells, dimension, merges, pane, cols, rows_meta, hl, elements

    def used_range(self, cells, merges=()):
        """Union of every cell reference AND every merged range.

        Excel's used range grows to cover a merge even when the covered cells
        carry no <c> element at all. `structure/merged-cells.xlsx` proves it.
        """
        refs = list(cells)
        for m in merges:
            refs.extend(m.split(":"))
        if not refs:
            return None
        r1 = c1 = 1 << 30
        r2 = c2 = 0
        for ref in refs:
            m = CELL_RE.match(ref)
            if not m:
                continue
            col, row = col_to_index(m.group(1)), int(m.group(2))
            r1, c1, r2, c2 = min(r1, row), min(c1, col), max(r2, row), max(c2, col)
        return f"{index_to_col(c1)}{r1}:{index_to_col(c2)}{r2}"


# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

def check_xlsx(path: str, exp: dict, rep: Report):
    rel = exp["file"]
    skip = set(exp.get("skipChecks", []))
    try:
        book = Book(path)
    except Exception as e:  # noqa: BLE001
        rep.fail(rel, f"could not open as xlsx: {type(e).__name__}: {e}")
        return

    rep.eq(rel, "dateSystem", exp.get("dateSystem", 1900), 1904 if book.date1904 else 1900)

    actual_names = [s["name"] for s in book.sheets]
    expected_names = [s["name"] for s in exp["sheets"]]
    if not rep.eq(rel, "sheet names", expected_names, actual_names):
        return

    for spec in exp["sheets"]:
        i = spec.get("index", 0)
        s = book.sheets[i]
        where = f"{rel} [{s['name']}]"
        rep.eq(where, "visibility", spec.get("visibility", "visible"), s["state"])

        (cells, dimension, merges, pane, cols,
         rows_meta, hyper, elements) = book.read_sheet(s["part"])

        if spec.get("dimension") is not None:
            rep.eq(where, "dimension", spec["dimension"], dimension)
        if spec.get("usedRange") is not None or "usedRange" in spec:
            # A merged range extends the used range even where no <c> exists.
            rep.eq(where, "usedRange", spec.get("usedRange"),
                   book.used_range(cells, merges))
        if "merges" in spec:
            rep.eq(where, "merges", sorted(spec["merges"]), sorted(merges))

        if "frozen" in spec:
            fz = spec["frozen"]
            if fz is None:
                if pane is not None and pane.get("state") == "frozen":
                    rep.fail(where, "expected no frozen pane, found one")
                else:
                    rep.ok(where, "no frozen pane")
            elif pane is None:
                rep.fail(where, "expected a frozen pane, found none")
            else:
                rep.eq(where, "frozen.columns", fz["columns"], int(float(pane.get("xSplit", 0))))
                rep.eq(where, "frozen.rows", fz["rows"], int(float(pane.get("ySplit", 0))))
                rep.eq(where, "frozen.topLeftCell", fz["topLeftCell"], pane.get("topLeftCell"))
                rep.eq(where, "frozen.state", fz["state"], pane.get("state"))

        if "split" in spec and spec["split"]:
            sp = spec["split"]
            rep.eq(where, "split.xSplitTwips", sp["xSplitTwips"], int(float(pane.get("xSplit", 0))))
            rep.eq(where, "split.ySplitTwips", sp["ySplitTwips"], int(float(pane.get("ySplit", 0))))
            if pane.get("state"):
                rep.fail(where, "split pane must NOT carry state=frozen")
            else:
                rep.ok(where, "split pane has no state attribute")

        if "columnWidths" in spec:
            actual = {}
            for c in cols:
                lo, hi = int(c["min"]), int(c["max"])
                key = str(lo) if lo == hi else f"{lo}-{hi}"
                actual[key] = float(c["width"])
            rep.eq(where, "columnWidths", spec["columnWidths"], actual)
        if "rowHeights" in spec:
            actual = {r: float(a["ht"]) for r, a in rows_meta.items() if "ht" in a}
            rep.eq(where, "rowHeights", spec["rowHeights"], actual)
        if "hyperlinks" in spec:
            rels = book._rels(os.path.join(os.path.dirname(s["part"]), "_rels",
                                           os.path.basename(s["part"]) + ".rels"))
            actual = {}
            for ref, h in hyper.items():
                rid = h.get(f"{R}id")
                actual[ref] = rels[rid][1] if rid else "#" + h.get("location", "")
            rep.eq(where, "hyperlinks", spec["hyperlinks"], actual)

        for el in exp.get("sheetLevelElementsThatMustSurvive", []):
            if i != 0:
                continue
            if el in elements:
                rep.ok(where, f"sheet-level <{el}> present")
            else:
                rep.fail(where, f"sidecar claims <{el}> is in this sheet part, but it is not")

        skip_formula = f"formulaText:{s['name']}" in skip
        for ref, want in spec.get("cells", {}).items():
            cwhere = f"{where} {ref}"
            got = cells.get(ref)
            if got is None:
                rep.fail(cwhere, "cell absent from the file")
                continue
            rep.eq(cwhere, "type", want["type"], got["type"])
            if f"cellValue:{s['name']}!{ref}" in skip:
                rep.ok(cwhere, "value not asserted (skipChecks)")
            elif want.get("value") is None and want["type"] != "empty":
                if got["value"] in (None, ""):
                    rep.fail(cwhere, "expected some value, found none")
                else:
                    rep.ok(cwhere, "value present (content not asserted)")
            elif want["type"] == "number":
                rep.eq(cwhere, "value", want["value"], got["value"], tol=1e-9)
            else:
                rep.eq(cwhere, "value", want["value"], got["value"])

            if "formula" in want and not skip_formula:
                rep.eq(cwhere, "formula", want["formula"], got["formula"])
            if want.get("numberFormat") is not None:
                rep.eq(cwhere, "numberFormat", want["numberFormat"], got["numberFormat"])

        for ref, length in exp.get("expectCellLength", {}).items():
            sn, cr = ref.split("!")
            if sn != s["name"]:
                continue
            rep.eq(f"{where} {cr}", "text length", length, len(cells[cr]["value"] or ""))

    if "definedNames" in exp:
        rep.eq(rel, "definedNames", exp["definedNames"], book.defined_names)

    if exp.get("containsMacros"):
        if "xl/vbaProject.bin" in book.names:
            rep.ok(rel, "xl/vbaProject.bin present")
        else:
            rep.fail(rel, "containsMacros but no xl/vbaProject.bin")

    for entry in exp.get("passthroughEntries", []):
        if entry in book.names:
            rep.ok(rel, f"passthrough entry {entry} present")
        else:
            rep.fail(rel, f"passthroughEntries names {entry}, which is not in the archive")

    for entry, meta in exp.get("zipEntries", {}).items():
        if entry not in book.names:
            rep.fail(rel, f"zipEntries names {entry}, which is not in the archive")
            continue
        got = hashlib.sha256(book.z.read(entry)).hexdigest()
        if got != meta["sha256"]:
            rep.fail(rel, f"{entry} sha256 drifted from the sidecar")
    if exp.get("zipEntries"):
        extra = set(book.names) - set(exp["zipEntries"])
        if extra:
            rep.fail(rel, f"archive has entries the sidecar does not list: {sorted(extra)}")
        else:
            rep.ok(rel, f"all {len(book.names)} zip entries hashed and accounted for")


def split_csv(data: str, delim: str, quote: str):
    """RFC 4180 by hand — csv.reader cannot be told that CR alone ends a row."""
    rows, field, row, i, inq = [], [], [], 0, False
    n = len(data)
    while i < n:
        ch = data[i]
        if inq:
            if ch == quote:
                if i + 1 < n and data[i + 1] == quote:
                    field.append(quote); i += 2; continue
                inq = False; i += 1; continue
            field.append(ch); i += 1; continue
        if ch == quote and not field:
            inq = True; i += 1; continue
        if ch == delim:
            row.append("".join(field)); field = []; i += 1; continue
        if ch in "\r\n":
            row.append("".join(field)); field = []
            rows.append(row); row = []
            if ch == "\r" and i + 1 < n and data[i + 1] == "\n":
                i += 2
            else:
                i += 1
            continue
        field.append(ch); i += 1
    if field or row:
        row.append("".join(field))
        rows.append(row)
    return rows


def check_csv(path: str, exp: dict, rep: Report):
    rel = exp["file"]
    skip = set(exp.get("skipChecks", []))
    size = os.path.getsize(path)
    if exp.get("generated") and size > 64 * 1024 * 1024:
        # a 2 GB fixture is checked at the head only; slurping it here would be
        # the exact mistake the fixture exists to catch
        raw = open(path, "rb").read(1 << 20)
        rep.ok(rel, f"{size / 1024 ** 3:.1f} GB present; head-only check")
    else:
        raw = open(path, "rb").read()
    d = exp["dialect"]

    boms = {"utf-8": b"\xef\xbb\xbf", "utf-16le": b"\xff\xfe", "utf-16be": b"\xfe\xff"}
    enc = d["encoding"].replace("windows-1252", "cp1252")
    if d["bom"]:
        want = boms[d["encoding"]]
        if raw.startswith(want):
            rep.ok(rel, f"{d['encoding']} BOM present")
            raw = raw[len(want):]
        else:
            rep.fail(rel, f"sidecar claims a {d['encoding']} BOM; first bytes are {raw[:4]!r}")
            return
    else:
        for b in boms.values():
            if raw.startswith(b):
                rep.fail(rel, f"sidecar says no BOM but the file starts with {b!r}")
                return

    if d["encoding"] == "windows-1252":
        try:
            raw.decode("utf-8")
            rep.fail(rel, "claims windows-1252 but the bytes are valid UTF-8, so the "
                          "fallback path would never be exercised")
        except UnicodeDecodeError:
            rep.ok(rel, "bytes are genuinely invalid UTF-8 (fallback is exercised)")

    try:
        text = raw.decode(enc)
    except UnicodeDecodeError as e:
        rep.fail(rel, f"does not decode as {enc}: {e}")
        return

    le = d["lineEnding"]
    if text and not (exp.get("generated") and size > 64 * 1024 * 1024):
        others = {"\r\n": ["\n"], "\n": ["\r"], "\r": ["\n"]}[le]
        stripped = text.replace(le, "\x01")
        leaked = [o for o in others if o in stripped and o not in "".join(
            f for r in exp["rows"] for f in r)]
        if leaked:
            rep.fail(rel, f"sidecar says lineEnding {le!r} but {leaked!r} also appears outside "
                          f"any quoted field")
        else:
            rep.ok(rel, f"lineEnding {le!r} is consistent")

    if "rows" in skip or (exp.get("generated") and size > 64 * 1024 * 1024):
        rep.ok(rel, "row content not asserted (skipChecks)")
        return

    rows = split_csv(text, d["delimiter"], d["quote"])
    rep.eq(rel, "rowCount", exp["rowCount"], len(rows))
    rep.eq(rel, "maxColumns", exp["maxColumns"], max((len(r) for r in rows), default=0))
    rep.eq(rel, "ragged", exp["ragged"], len({len(r) for r in rows}) > 1)
    for i, (want, got) in enumerate(zip(exp["rows"], rows)):
        if want != got:
            rep.fail(rel, f"row {i}: expected {want!r}, got {got!r}")
    if exp["rows"] == rows:
        rep.ok(rel, f"all {len(rows)} rows match")


def check_hostile(rep: Report):
    p = os.path.join(FIXTURES, "hostile", "expected-errors.json")
    if not os.path.exists(p):
        rep.fail("hostile", "expected-errors.json is missing")
        return
    doc = json.load(open(p, encoding="utf-8"))
    named = {c["file"] for c in doc["cases"]}
    on_disk = {f"hostile/{f}" for f in os.listdir(os.path.join(FIXTURES, "hostile"))
               if f != "expected-errors.json" and not f.endswith(".expected.json")}
    for f in sorted(on_disk - named):
        rep.fail("hostile", f"{f} has no entry in expected-errors.json")
    for f in sorted(named - on_disk):
        rep.fail("hostile", f"expected-errors.json names {f}, which does not exist")
    if on_disk == named:
        rep.ok("hostile", f"all {len(on_disk)} hostile files are covered")

    for case in doc["cases"]:
        w = case["file"]
        if not case.get("proves"):
            rep.fail(w, "no `proves` line")
        if case["expectedError"] is None and case["expectedBehavior"] == "throw":
            rep.fail(w, "expectedError is null but expectedBehavior is 'throw'")
        code = case["expectedError"] or ""
        if code and not re.match(r"^(zip|xml|xlsx)\.[a-zA-Z]+$", code):
            rep.fail(w, f"error code {code!r} is not <namespace>.<lowerCamelCase>")
        if not case["mustNotHappen"]:
            rep.fail(w, "mustNotHappen is empty")
    rep.ok("hostile", f"{len(doc['cases'])} cases well-formed")


def check_hostile_properties(rep: Report):
    """Prove each hostile fixture is actually hostile.

    A "malformed" file that quietly became well-formed is worse than no test at
    all: the suite goes green while the defence it was written for is untested.
    """
    d = os.path.join(FIXTURES, "hostile")

    def raw(name):
        return open(os.path.join(d, name), "rb").read()

    def entries(name):
        """Walk the central directory by hand — zipfile hides the lies."""
        b = raw(name)
        i = b.rfind(b"PK\x05\x06")
        if i < 0:
            return None
        count = int.from_bytes(b[i + 10:i + 12], "little")
        off = int.from_bytes(b[i + 16:i + 20], "little")
        out = []
        for _ in range(count):
            if b[off:off + 4] != b"PK\x01\x02":
                break
            method = int.from_bytes(b[off + 10:off + 12], "little")
            crc = int.from_bytes(b[off + 16:off + 20], "little")
            csize = int.from_bytes(b[off + 20:off + 24], "little")
            usize = int.from_bytes(b[off + 24:off + 28], "little")
            nlen = int.from_bytes(b[off + 28:off + 30], "little")
            elen = int.from_bytes(b[off + 30:off + 32], "little")
            clen = int.from_bytes(b[off + 32:off + 34], "little")
            nm = b[off + 46:off + 46 + nlen]
            extra = b[off + 46 + nlen:off + 46 + nlen + elen]
            if usize == 0xFFFFFFFF and len(extra) >= 20 and extra[:2] == b"\x01\x00":
                usize = int.from_bytes(extra[4:12], "little")
            out.append({"name": nm, "method": method, "crc": crc,
                        "csize": csize, "usize": usize})
            off += 46 + nlen + elen + clen
        return out

    def want(name, cond, what):
        if cond:
            rep.ok(f"hostile/{name}", what)
        else:
            rep.fail(f"hostile/{name}", f"is NOT hostile any more: {what}")

    e = entries("zip-bomb.xlsx")
    big = max(e, key=lambda x: x["usize"])
    want("zip-bomb.xlsx", big["usize"] / max(big["csize"], 1) > 100,
         f"ratio {big['usize'] // max(big['csize'], 1)}:1 exceeds the 100:1 cap")

    e = entries("lying-uncompressed-size.xlsx")
    liar = max(e, key=lambda x: x["usize"])
    want("lying-uncompressed-size.xlsx", liar["usize"] >= 10 * 1024 ** 3,
         f"ZIP64 declares {liar['usize'] / 1024 ** 3:.0f} GB uncompressed")

    for name, pred, what in [
        ("path-traversal.xlsx", lambda x: b".." in x["name"], "an entry name contains .."),
        ("absolute-path-entry.xlsx",
         lambda x: x["name"].startswith(b"/") or b":\\" in x["name"],
         "an entry name is absolute"),
        ("nul-in-entry-name.xlsx", lambda x: b"\x00" in x["name"],
         "an entry name contains a NUL byte"),
        ("unsupported-compression-method.xlsx", lambda x: x["method"] not in (0, 8),
         "an entry uses a compression method other than store/deflate"),
    ]:
        want(name, any(pred(x) for x in entries(name)), what)

    names = [x["name"] for x in entries("duplicate-entries.xlsx")]
    want("duplicate-entries.xlsx", len(names) != len(set(names)),
         "two entries share a name")

    import zlib
    e = entries("crc-mismatch.xlsx")
    z = zipfile.ZipFile(os.path.join(d, "crc-mismatch.xlsx"))
    bad = False
    for info in z.infolist():
        try:
            data = z.read(info.filename)
        except zipfile.BadZipFile:
            bad = True
            break
        if zlib.crc32(data) & 0xFFFFFFFF != info.CRC:
            bad = True
    want("crc-mismatch.xlsx", bad, "an entry's stored CRC32 does not match its data")

    want("truncated.xlsx", b"PK\x05\x06" not in raw("truncated.xlsx"),
         "there is no end-of-central-directory record")
    want("not-a-zip.xlsx", not raw("not-a-zip.xlsx").startswith(b"PK"),
         "the file does not start with the ZIP magic")
    want("encrypted.xlsx", raw("encrypted.xlsx").startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")
         and b"E\x00n\x00c\x00r\x00y\x00p\x00t\x00e\x00d" in raw("encrypted.xlsx"),
         "it is an OLE2/CFB container advertising EncryptedPackage")
    want("entry-count-bomb.xlsx", len(entries("entry-count-bomb.xlsx")) > 10000,
         f"it holds {len(entries('entry-count-bomb.xlsx'))} entries (cap is 10,000)")

    def part(name, member):
        return zipfile.ZipFile(os.path.join(d, name)).read(member)

    want("xxe-external-entity.xlsx",
         b"<!DOCTYPE" in part("xxe-external-entity.xlsx", "xl/sharedStrings.xml")
         and b"file:///etc/passwd" in part("xxe-external-entity.xlsx", "xl/sharedStrings.xml"),
         "sharedStrings declares an external entity pointing at /etc/passwd")
    want("billion-laughs.xlsx",
         part("billion-laughs.xlsx", "xl/sharedStrings.xml").count(b"<!ENTITY") >= 10,
         "sharedStrings declares 10 nested entities")
    want("dtd-doctype.xlsx", b"<!DOCTYPE" in part("dtd-doctype.xlsx", "xl/sharedStrings.xml"),
         "sharedStrings carries a DOCTYPE")
    want("nul-bytes-in-string.xlsx",
         b"\x00" in part("nul-bytes-in-string.xlsx", "xl/sharedStrings.xml"),
         "a shared string contains a raw NUL byte")
    want("deep-nesting-100k.xlsx",
         part("deep-nesting-100k.xlsx", "xl/worksheets/sheet1.xml").count(b"<a>") >= 100000,
         "the sheet nests 100,000 elements deep")
    want("cell-40k-chars.xlsx",
         max(len(t) for t in re.findall(
             rb"<t>(.*?)</t>", part("cell-40k-chars.xlsx", "xl/worksheets/sheet1.xml"))) > 32767,
         "a cell holds more than 32,767 characters")
    want("dimension-4-billion-rows.xlsx",
         b"4294967296" in part("dimension-4-billion-rows.xlsx", "xl/worksheets/sheet1.xml"),
         "<dimension> claims more than 2^32 rows")
    want("missing-workbook-part.xlsx",
         "xl/workbook.xml" not in zipfile.ZipFile(
             os.path.join(d, "missing-workbook-part.xlsx")).namelist(),
         "xl/workbook.xml is absent while the rels still point at it")
    try:
        ET.fromstring(part("malformed-xml.xlsx", "xl/worksheets/sheet1.xml"))
        want("malformed-xml.xlsx", False, "the sheet XML is unparseable")
    except ET.ParseError:
        want("malformed-xml.xlsx", True, "the sheet XML is unparseable")
    for bad_ref in (b'r="0"', b'r=""', b'r="ZZZZZ1"'):
        want("invalid-cell-reference.xlsx",
             bad_ref in part("invalid-cell-reference.xlsx", "xl/worksheets/sheet1.xml"),
             f"the sheet contains {bad_ref.decode()}")
    outer = zipfile.ZipFile(os.path.join(d, "zip-bomb-nested.xlsx"))
    ratio = 0
    if "xl/media/payload.zip" in outer.namelist():
        import io as _io
        mid = zipfile.ZipFile(_io.BytesIO(outer.read("xl/media/payload.zip")))
        deepest = zipfile.ZipFile(_io.BytesIO(mid.read("nested.zip")))
        i = deepest.infolist()[0]
        ratio = i.file_size / max(i.compress_size, 1)
    want("zip-bomb-nested.xlsx",
         ratio > 100 and outer.read("xl/workbook.xml").startswith(b"<?xml"),
         f"a {ratio:.0f}:1 bomb sits two archives deep inside xl/media/ while the "
         f"workbook itself stays valid")


def check_readme(rep: Report):
    p = os.path.join(FIXTURES, "README.md")
    if not os.path.exists(p):
        rep.fail("README", "Fixtures/README.md is missing")
        return
    text = open(p, encoding="utf-8").read()
    missing = []
    documented = set()
    for root, _, files in os.walk(FIXTURES):
        for f in files:
            if f == "README.md":
                continue
            if f.endswith(".expected.json"):
                f = f[: -len(".expected.json")]        # covers git-ignored fixtures too
            relp = os.path.relpath(os.path.join(root, f), FIXTURES).replace(os.sep, "/")
            if relp in documented:
                continue
            documented.add(relp)
            if f"`{relp}`" not in text and relp not in text:
                missing.append(relp)
    if missing:
        for m in sorted(missing):
            rep.fail("README", f"{m} is not documented in Fixtures/README.md")
    else:
        rep.ok("README", "every fixture is documented")


SOFFICE = "/Applications/LibreOffice.app/Contents/MacOS/soffice"


def check_loads_in_a_real_app(rep: Report):
    """Open every non-hostile fixture in LibreOffice.

    A hand-authored OOXML part can satisfy every assertion in this script and
    still be a file no spreadsheet will open. This is the check that catches
    that, and it is why `passthrough/pivot-table.xlsx` is known to be a real
    pivot table rather than plausible-looking XML.
    """
    import subprocess
    import tempfile
    if not os.path.exists(SOFFICE):
        rep.warn("load-test", "LibreOffice not installed; skipped")
        return
    files = []
    for root, _, names in os.walk(FIXTURES):
        if os.path.basename(root) == "hostile":
            continue
        for n in sorted(names):
            if n.endswith((".xlsx", ".xlsm")) and "1m-cells" not in n:
                files.append(os.path.join(root, n))
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "out")
        os.makedirs(out)
        for f in files:
            r = subprocess.run(
                [SOFFICE, "--headless", "--norestore",
                 f"-env:UserInstallation=file://{td}/p",
                 "--convert-to", "ods", "--outdir", out, f],
                capture_output=True, text=True, timeout=300)
            produced = os.path.join(
                out, os.path.splitext(os.path.basename(f))[0] + ".ods")
            rel = os.path.relpath(f, FIXTURES).replace(os.sep, "/")
            if os.path.exists(produced):
                rep.ok(rel, "opens in LibreOffice Calc")
            else:
                rep.fail(rel, f"LibreOffice cannot open it: {r.stdout.strip()} "
                              f"{r.stderr.strip()}")


def check_orphans(rep: Report):
    for root, _, files in os.walk(FIXTURES):
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, FIXTURES).replace(os.sep, "/")
            if f.endswith(".expected.json"):
                target = full[: -len(".expected.json")]
                if not os.path.exists(target):
                    exp = json.load(open(full, encoding="utf-8"))
                    if not exp.get("generated"):
                        rep.fail(rel, "sidecar with no fixture")
            elif f in ("README.md", "expected-errors.json") or rel.startswith("hostile/"):
                continue
            elif not os.path.exists(full + ".expected.json"):
                rep.fail(rel, "fixture with no .expected.json sidecar")


# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("groups", nargs="*")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--load-test", action="store_true",
                    help="also open every non-hostile fixture in LibreOffice (slow, ~90 s)")
    args = ap.parse_args(argv)

    rep = Report(args.verbose)
    sidecars = []
    for root, _, files in os.walk(FIXTURES):
        for f in files:
            if f.endswith(".expected.json"):
                sidecars.append(os.path.join(root, f))
    sidecars.sort()

    for side in sidecars:
        exp = json.load(open(side, encoding="utf-8"))
        rel = exp["file"]
        if args.groups and rel.split("/")[0] not in args.groups:
            continue
        target = side[: -len(".expected.json")]
        if not os.path.exists(target):
            if exp.get("generated"):
                rep.warn(rel, "git-ignored; rebuild with "
                              "`gen-fixtures.py perf --with-huge` before the perf suite")
            else:
                rep.fail(rel, "fixture file is missing (regenerate with gen-fixtures.py)")
            continue
        rep.files += 1
        print(f"  {rel}")
        for field in ("proves", "valuesVerifiedBy"):
            if not exp.get(field):
                rep.fail(rel, f"sidecar has no `{field}`")
        if exp.get("kind") == "csv":
            check_csv(target, exp, rep)
        else:
            check_xlsx(target, exp, rep)

    if not args.groups or "hostile" in args.groups:
        print("  hostile/expected-errors.json")
        check_hostile(rep)
        check_hostile_properties(rep)
    if not args.groups:
        check_orphans(rep)
        check_readme(rep)
    if args.load_test:
        print("  load test (LibreOffice)")
        check_loads_in_a_real_app(rep)

    print()
    print(f"{rep.files} fixtures, {rep.checks} checks, "
          f"{len(rep.failures)} failures, {len(rep.warnings)} warnings")
    if rep.failures:
        print("\nFAILURES")
        for where, what in rep.failures:
            print(f"  {where}: {what}")
        return 1
    print("green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
