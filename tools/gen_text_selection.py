"""Generate the checked-in Unicode 17.0.0 selection tables (offline inputs).

Inputs are the official UCD GraphemeBreakProperty, emoji-data,
DerivedCoreProperties, UnicodeData, and GraphemeBreakTest files. No locale or
regex dependency. Outputs are split across files to stay within nanoui's
600-line limit.
"""

from pathlib import Path
import argparse

HEADER = """//! Generated from Unicode 17.0.0 UCD, not platform/locale heuristics.
//! https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt
//! https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt
//! https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt (InCB)
//! https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt (letters/numbers)
//! Unicode data license: ../../third_party/licenses/Unicode-3.0.txt.
"""


def merge(items):
    items = sorted(items)
    result = []
    for a, b, p in items:
        if result and a == result[-1][1] + 1 and p == result[-1][2]:
            result[-1] = (result[-1][0], b, p)
        else:
            result.append((a, b, p))
    return result


def ranges(src_dir: Path, filename: str, select):
    result = []
    for line in (src_dir / filename).read_text().splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        fields = [p.strip() for p in line.split(";")]
        prop = select(fields)
        if prop is None:
            continue
        ab = fields[0].split("..")
        a = int(ab[0], 16)
        b = int(ab[-1], 16)
        result.append((a, b, prop))
    return merge(result)


def format_array(name: str, kind: str, items, prefix: str = "") -> str:
    lines = [f"pub const {name} = [_]{prefix}Range({kind}){{"]
    for a, b, p in items:
        val = p if kind == "bool" else f".{p}"
        lines.append(f"    .{{ .first = 0x{a:X}, .last = 0x{b:X}, .value = {val} }},")
    lines.append("};")
    return "\n".join(lines) + "\n"


def split_plane(items):
    bmp = [item for item in items if item[0] <= 0xFFFF]
    smp = [item for item in items if item[0] > 0xFFFF]
    return bmp, smp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "ucd_dir",
        type=Path,
        help="Directory containing the five pinned Unicode 17 UCD files",
    )
    args = parser.parse_args()
    src = args.ucd_dir
    out = Path(__file__).resolve().parent.parent / "src" / "ui"

    gcb = ranges(
        src,
        "GraphemeBreakProperty.txt",
        lambda f: None if f[1] in ("LV", "LVT") else f[1].lower(),
    )
    ep = ranges(
        src,
        "emoji-data.txt",
        lambda f: "true" if f[1] == "Extended_Pictographic" else None,
    )
    incb = ranges(
        src,
        "DerivedCoreProperties.txt",
        lambda f: f[2].lower() if f[1] == "InCB" else None,
    )

    words = []
    pending = None
    for line in (src / "UnicodeData.txt").read_text().splitlines():
        f = line.split(";")
        cp = int(f[0], 16)
        if f[1].endswith(", First>"):
            pending = cp
            continue
        if f[1].endswith(", Last>"):
            if f[2][0] in "LN":
                words.append((pending, cp, "true"))
            pending = None
        elif f[2][0] in "LN":
            words.append((cp, cp, "true"))
    words = merge(words)

    gcb_bmp, gcb_smp = split_plane(gcb)
    words_bmp, words_smp = split_plane(words)

    data_zig = (
        HEADER
        + "//! Hangul LV/LVT syllables are classified algorithmically by the caller.\n"
        + "pub const Break = enum { other, cr, lf, control, extend, zwj, regional_indicator, prepend, spacingmark, l, v, t, lv, lvt };\n"
        + "pub const Indic = enum { none, consonant, extend, linker };\n\n"
        + "pub fn Range(comptime T: type) type {\n"
        + "    return struct { first: u21, last: u21, value: T };\n"
        + "}\n\n"
        + "pub fn lookup(comptime T: type, table: []const Range(T), cp: u21, fallback: T) T {\n"
        + "    var lo: usize = 0;\n"
        + "    var hi = table.len;\n"
        + "    while (lo < hi) {\n"
        + "        const mid = lo + (hi - lo) / 2;\n"
        + "        const r = table[mid];\n"
        + "        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.value;\n"
        + "    }\n"
        + "    return fallback;\n"
        + "}\n\n"
        + "pub fn breakOf(cp: u21) Break {\n"
        + '    const table = if (cp <= 0xFFFF) &@import("text_selection_breaks_bmp.zig").breaks_bmp else &@import("text_selection_breaks_smp.zig").breaks_smp;\n'
        + "    return lookup(Break, table, cp, .other);\n"
        + "}\n\n"
        + "pub fn isPictographic(cp: u21) bool {\n"
        + "    return lookup(bool, &pictographic, cp, false);\n"
        + "}\n\n"
        + "pub fn indicOf(cp: u21) Indic {\n"
        + '    return lookup(Indic, &@import("text_selection_indic.zig").indic, cp, .none);\n'
        + "}\n\n"
        + "pub fn isWord(cp: u21) bool {\n"
        + '    const table = if (cp <= 0xFFFF) &@import("text_selection_words_bmp.zig").words_bmp else &@import("text_selection_words_smp.zig").words_smp;\n'
        + "    return lookup(bool, table, cp, false);\n"
        + "}\n\n"
        + format_array("pictographic", "bool", ep)
    )
    (out / "text_selection_data.zig").write_text(data_zig)

    parts = [
        ("text_selection_breaks_bmp.zig", "breaks_bmp", "data.Break", gcb_bmp),
        ("text_selection_breaks_smp.zig", "breaks_smp", "data.Break", gcb_smp),
        ("text_selection_indic.zig", "indic", "data.Indic", incb),
        ("text_selection_words_bmp.zig", "words_bmp", "bool", words_bmp),
        ("text_selection_words_smp.zig", "words_smp", "bool", words_smp),
    ]
    for fname, sym, kind, items in parts:
        src_text = (
            HEADER
            + 'const data = @import("text_selection_data.zig");\n\n'
            + format_array(sym, kind, items, prefix="data.")
        )
        (out / fname).write_text(src_text)

    test_lines = (src / "GraphemeBreakTest.txt").read_text().splitlines(keepends=True)
    mid = (len(test_lines) + 1) // 2
    (out / "grapheme_break_test_1.txt").write_text("".join(test_lines[:mid]))
    (out / "grapheme_break_test_2.txt").write_text("".join(test_lines[mid:]))
    print("Generated tables:", len(gcb), len(ep), len(incb), len(words))


if __name__ == "__main__":
    main()
