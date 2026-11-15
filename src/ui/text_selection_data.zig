//! Generated from Unicode 17.0.0 UCD, not platform/locale heuristics.
//! https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt
//! https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt
//! https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt (InCB)
//! https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt (letters/numbers)
//! Unicode data license: ../../third_party/licenses/Unicode-3.0.txt.
//! Hangul LV/LVT syllables are classified algorithmically by the caller.
pub const Break = enum { other, cr, lf, control, extend, zwj, regional_indicator, prepend, spacingmark, l, v, t, lv, lvt };
pub const Indic = enum { none, consonant, extend, linker };

pub fn Range(comptime T: type) type {
    return struct { first: u21, last: u21, value: T };
}

pub fn lookup(comptime T: type, table: []const Range(T), cp: u21, fallback: T) T {
    var lo: usize = 0;
    var hi = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.value;
    }
    return fallback;
}

pub fn breakOf(cp: u21) Break {
    const table = if (cp <= 0xFFFF) &@import("text_selection_breaks_bmp.zig").breaks_bmp else &@import("text_selection_breaks_smp.zig").breaks_smp;
    return lookup(Break, table, cp, .other);
}

pub fn isPictographic(cp: u21) bool {
    return lookup(bool, &pictographic, cp, false);
}

pub fn indicOf(cp: u21) Indic {
    return lookup(Indic, &@import("text_selection_indic.zig").indic, cp, .none);
}

pub fn isWord(cp: u21) bool {
    const table = if (cp <= 0xFFFF) &@import("text_selection_words_bmp.zig").words_bmp else &@import("text_selection_words_smp.zig").words_smp;
    return lookup(bool, table, cp, false);
}

pub const pictographic = [_]Range(bool){
    .{ .first = 0xA9, .last = 0xA9, .value = true },
    .{ .first = 0xAE, .last = 0xAE, .value = true },
    .{ .first = 0x203C, .last = 0x203C, .value = true },
    .{ .first = 0x2049, .last = 0x2049, .value = true },
    .{ .first = 0x2122, .last = 0x2122, .value = true },
    .{ .first = 0x2139, .last = 0x2139, .value = true },
    .{ .first = 0x2194, .last = 0x2199, .value = true },
    .{ .first = 0x21A9, .last = 0x21AA, .value = true },
    .{ .first = 0x231A, .last = 0x231B, .value = true },
    .{ .first = 0x2328, .last = 0x2328, .value = true },
    .{ .first = 0x23CF, .last = 0x23CF, .value = true },
    .{ .first = 0x23E9, .last = 0x23F3, .value = true },
    .{ .first = 0x23F8, .last = 0x23FA, .value = true },
    .{ .first = 0x24C2, .last = 0x24C2, .value = true },
    .{ .first = 0x25AA, .last = 0x25AB, .value = true },
    .{ .first = 0x25B6, .last = 0x25B6, .value = true },
    .{ .first = 0x25C0, .last = 0x25C0, .value = true },
    .{ .first = 0x25FB, .last = 0x25FE, .value = true },
    .{ .first = 0x2600, .last = 0x2604, .value = true },
    .{ .first = 0x260E, .last = 0x260E, .value = true },
    .{ .first = 0x2611, .last = 0x2611, .value = true },
    .{ .first = 0x2614, .last = 0x2615, .value = true },
    .{ .first = 0x2618, .last = 0x2618, .value = true },
    .{ .first = 0x261D, .last = 0x261D, .value = true },
    .{ .first = 0x2620, .last = 0x2620, .value = true },
    .{ .first = 0x2622, .last = 0x2623, .value = true },
    .{ .first = 0x2626, .last = 0x2626, .value = true },
    .{ .first = 0x262A, .last = 0x262A, .value = true },
    .{ .first = 0x262E, .last = 0x262F, .value = true },
    .{ .first = 0x2638, .last = 0x263A, .value = true },
    .{ .first = 0x2640, .last = 0x2640, .value = true },
    .{ .first = 0x2642, .last = 0x2642, .value = true },
    .{ .first = 0x2648, .last = 0x2653, .value = true },
    .{ .first = 0x265F, .last = 0x2660, .value = true },
    .{ .first = 0x2663, .last = 0x2663, .value = true },
    .{ .first = 0x2665, .last = 0x2666, .value = true },
    .{ .first = 0x2668, .last = 0x2668, .value = true },
    .{ .first = 0x267B, .last = 0x267B, .value = true },
    .{ .first = 0x267E, .last = 0x267F, .value = true },
    .{ .first = 0x2692, .last = 0x2697, .value = true },
    .{ .first = 0x2699, .last = 0x2699, .value = true },
    .{ .first = 0x269B, .last = 0x269C, .value = true },
    .{ .first = 0x26A0, .last = 0x26A1, .value = true },
    .{ .first = 0x26A7, .last = 0x26A7, .value = true },
    .{ .first = 0x26AA, .last = 0x26AB, .value = true },
    .{ .first = 0x26B0, .last = 0x26B1, .value = true },
    .{ .first = 0x26BD, .last = 0x26BE, .value = true },
    .{ .first = 0x26C4, .last = 0x26C5, .value = true },
    .{ .first = 0x26C8, .last = 0x26C8, .value = true },
    .{ .first = 0x26CE, .last = 0x26CF, .value = true },
    .{ .first = 0x26D1, .last = 0x26D1, .value = true },
    .{ .first = 0x26D3, .last = 0x26D4, .value = true },
    .{ .first = 0x26E9, .last = 0x26EA, .value = true },
    .{ .first = 0x26F0, .last = 0x26F5, .value = true },
    .{ .first = 0x26F7, .last = 0x26FA, .value = true },
    .{ .first = 0x26FD, .last = 0x26FD, .value = true },
    .{ .first = 0x2702, .last = 0x2702, .value = true },
    .{ .first = 0x2705, .last = 0x2705, .value = true },
    .{ .first = 0x2708, .last = 0x270D, .value = true },
    .{ .first = 0x270F, .last = 0x270F, .value = true },
    .{ .first = 0x2712, .last = 0x2712, .value = true },
    .{ .first = 0x2714, .last = 0x2714, .value = true },
    .{ .first = 0x2716, .last = 0x2716, .value = true },
    .{ .first = 0x271D, .last = 0x271D, .value = true },
    .{ .first = 0x2721, .last = 0x2721, .value = true },
    .{ .first = 0x2728, .last = 0x2728, .value = true },
    .{ .first = 0x2733, .last = 0x2734, .value = true },
    .{ .first = 0x2744, .last = 0x2744, .value = true },
    .{ .first = 0x2747, .last = 0x2747, .value = true },
    .{ .first = 0x274C, .last = 0x274C, .value = true },
    .{ .first = 0x274E, .last = 0x274E, .value = true },
    .{ .first = 0x2753, .last = 0x2755, .value = true },
    .{ .first = 0x2757, .last = 0x2757, .value = true },
    .{ .first = 0x2763, .last = 0x2764, .value = true },
    .{ .first = 0x2795, .last = 0x2797, .value = true },
    .{ .first = 0x27A1, .last = 0x27A1, .value = true },
    .{ .first = 0x27B0, .last = 0x27B0, .value = true },
    .{ .first = 0x27BF, .last = 0x27BF, .value = true },
    .{ .first = 0x2934, .last = 0x2935, .value = true },
    .{ .first = 0x2B05, .last = 0x2B07, .value = true },
    .{ .first = 0x2B1B, .last = 0x2B1C, .value = true },
    .{ .first = 0x2B50, .last = 0x2B50, .value = true },
    .{ .first = 0x2B55, .last = 0x2B55, .value = true },
    .{ .first = 0x3030, .last = 0x3030, .value = true },
    .{ .first = 0x303D, .last = 0x303D, .value = true },
    .{ .first = 0x3297, .last = 0x3297, .value = true },
    .{ .first = 0x3299, .last = 0x3299, .value = true },
    .{ .first = 0x1F004, .last = 0x1F004, .value = true },
    .{ .first = 0x1F02C, .last = 0x1F02F, .value = true },
    .{ .first = 0x1F094, .last = 0x1F09F, .value = true },
    .{ .first = 0x1F0AF, .last = 0x1F0B0, .value = true },
    .{ .first = 0x1F0C0, .last = 0x1F0C0, .value = true },
    .{ .first = 0x1F0CF, .last = 0x1F0D0, .value = true },
    .{ .first = 0x1F0F6, .last = 0x1F0FF, .value = true },
    .{ .first = 0x1F170, .last = 0x1F171, .value = true },
    .{ .first = 0x1F17E, .last = 0x1F17F, .value = true },
    .{ .first = 0x1F18E, .last = 0x1F18E, .value = true },
    .{ .first = 0x1F191, .last = 0x1F19A, .value = true },
    .{ .first = 0x1F1AE, .last = 0x1F1E5, .value = true },
    .{ .first = 0x1F201, .last = 0x1F20F, .value = true },
    .{ .first = 0x1F21A, .last = 0x1F21A, .value = true },
    .{ .first = 0x1F22F, .last = 0x1F22F, .value = true },
    .{ .first = 0x1F232, .last = 0x1F23A, .value = true },
    .{ .first = 0x1F23C, .last = 0x1F23F, .value = true },
    .{ .first = 0x1F249, .last = 0x1F25F, .value = true },
    .{ .first = 0x1F266, .last = 0x1F321, .value = true },
    .{ .first = 0x1F324, .last = 0x1F393, .value = true },
    .{ .first = 0x1F396, .last = 0x1F397, .value = true },
    .{ .first = 0x1F399, .last = 0x1F39B, .value = true },
    .{ .first = 0x1F39E, .last = 0x1F3F0, .value = true },
    .{ .first = 0x1F3F3, .last = 0x1F3F5, .value = true },
    .{ .first = 0x1F3F7, .last = 0x1F3FA, .value = true },
    .{ .first = 0x1F400, .last = 0x1F4FD, .value = true },
    .{ .first = 0x1F4FF, .last = 0x1F53D, .value = true },
    .{ .first = 0x1F549, .last = 0x1F54E, .value = true },
    .{ .first = 0x1F550, .last = 0x1F567, .value = true },
    .{ .first = 0x1F56F, .last = 0x1F570, .value = true },
    .{ .first = 0x1F573, .last = 0x1F57A, .value = true },
    .{ .first = 0x1F587, .last = 0x1F587, .value = true },
    .{ .first = 0x1F58A, .last = 0x1F58D, .value = true },
    .{ .first = 0x1F590, .last = 0x1F590, .value = true },
    .{ .first = 0x1F595, .last = 0x1F596, .value = true },
    .{ .first = 0x1F5A4, .last = 0x1F5A5, .value = true },
    .{ .first = 0x1F5A8, .last = 0x1F5A8, .value = true },
    .{ .first = 0x1F5B1, .last = 0x1F5B2, .value = true },
    .{ .first = 0x1F5BC, .last = 0x1F5BC, .value = true },
    .{ .first = 0x1F5C2, .last = 0x1F5C4, .value = true },
    .{ .first = 0x1F5D1, .last = 0x1F5D3, .value = true },
    .{ .first = 0x1F5DC, .last = 0x1F5DE, .value = true },
    .{ .first = 0x1F5E1, .last = 0x1F5E1, .value = true },
    .{ .first = 0x1F5E3, .last = 0x1F5E3, .value = true },
    .{ .first = 0x1F5E8, .last = 0x1F5E8, .value = true },
    .{ .first = 0x1F5EF, .last = 0x1F5EF, .value = true },
    .{ .first = 0x1F5F3, .last = 0x1F5F3, .value = true },
    .{ .first = 0x1F5FA, .last = 0x1F64F, .value = true },
    .{ .first = 0x1F680, .last = 0x1F6C5, .value = true },
    .{ .first = 0x1F6CB, .last = 0x1F6D2, .value = true },
    .{ .first = 0x1F6D5, .last = 0x1F6E5, .value = true },
    .{ .first = 0x1F6E9, .last = 0x1F6E9, .value = true },
    .{ .first = 0x1F6EB, .last = 0x1F6F0, .value = true },
    .{ .first = 0x1F6F3, .last = 0x1F6FF, .value = true },
    .{ .first = 0x1F7DA, .last = 0x1F7FF, .value = true },
    .{ .first = 0x1F80C, .last = 0x1F80F, .value = true },
    .{ .first = 0x1F848, .last = 0x1F84F, .value = true },
    .{ .first = 0x1F85A, .last = 0x1F85F, .value = true },
    .{ .first = 0x1F888, .last = 0x1F88F, .value = true },
    .{ .first = 0x1F8AE, .last = 0x1F8AF, .value = true },
    .{ .first = 0x1F8BC, .last = 0x1F8BF, .value = true },
    .{ .first = 0x1F8C2, .last = 0x1F8CF, .value = true },
    .{ .first = 0x1F8D9, .last = 0x1F8FF, .value = true },
    .{ .first = 0x1F90C, .last = 0x1F93A, .value = true },
    .{ .first = 0x1F93C, .last = 0x1F945, .value = true },
    .{ .first = 0x1F947, .last = 0x1F9FF, .value = true },
    .{ .first = 0x1FA58, .last = 0x1FA5F, .value = true },
    .{ .first = 0x1FA6E, .last = 0x1FAFF, .value = true },
    .{ .first = 0x1FC00, .last = 0x1FFFD, .value = true },
};
