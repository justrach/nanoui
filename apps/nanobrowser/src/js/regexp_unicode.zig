//! Character sets for regular expressions: \d \w \s, range arithmetic, simple case
//! folding, and approximate tables for \p{...} covering the General_Category and Script
//! names real code uses. The tables are coarse block ranges, not the UCD.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Range = struct { lo: u32, hi: u32 };

const List = std.ArrayList(Range);

fn addAll(l: *List, a: Allocator, rs: []const Range) Allocator.Error!void {
    try l.appendSlice(a, rs);
}

pub fn addDigit(l: *List, a: Allocator) Allocator.Error!void {
    try l.append(a, .{ .lo = '0', .hi = '9' });
}

pub const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };

pub fn addWord(l: *List, a: Allocator) Allocator.Error!void {
    try addAll(l, a, &word_ranges);
}

pub const space_ranges = [_]Range{
    .{ .lo = 9, .hi = 13 },          .{ .lo = ' ', .hi = ' ' },       .{ .lo = 0xA0, .hi = 0xA0 },
    .{ .lo = 0x1680, .hi = 0x1680 }, .{ .lo = 0x2000, .hi = 0x200A }, .{ .lo = 0x2028, .hi = 0x2029 },
    .{ .lo = 0x202F, .hi = 0x202F }, .{ .lo = 0x205F, .hi = 0x205F }, .{ .lo = 0x3000, .hi = 0x3000 },
    .{ .lo = 0xFEFF, .hi = 0xFEFF },
};

pub fn addSpace(l: *List, a: Allocator) Allocator.Error!void {
    try addAll(l, a, &space_ranges);
}

/// Sorted, merged copy of a range list.
pub fn normalized(a: Allocator, rs: []const Range) Allocator.Error!List {
    var out: List = .empty;
    const tmp = try a.dupe(Range, rs);
    std.mem.sort(Range, tmp, {}, struct {
        fn lt(_: void, x: Range, y: Range) bool {
            return x.lo < y.lo;
        }
    }.lt);
    for (tmp) |r| {
        if (out.items.len != 0 and r.lo <= out.items[out.items.len - 1].hi +| 1) {
            const last = &out.items[out.items.len - 1];
            last.hi = @max(last.hi, r.hi);
        } else try out.append(a, r);
    }
    return out;
}

pub fn negated(a: Allocator, rs: []const Range) Allocator.Error!List {
    const n = try normalized(a, rs);
    var out: List = .empty;
    var next: u32 = 0;
    for (n.items) |r| {
        if (r.lo > next) try out.append(a, .{ .lo = next, .hi = r.lo - 1 });
        next = r.hi + 1;
    }
    if (next <= 0x10FFFF) try out.append(a, .{ .lo = next, .hi = 0x10FFFF });
    return out;
}

const lu = [_]Range{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 0xC0, .hi = 0xD6 }, .{ .lo = 0xD8, .hi = 0xDE }, .{ .lo = 0x391, .hi = 0x3A9 }, .{ .lo = 0x410, .hi = 0x42F }, .{ .lo = 0x400, .hi = 0x40F } };
const ll = [_]Range{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xB5, .hi = 0xB5 }, .{ .lo = 0xDF, .hi = 0xF6 }, .{ .lo = 0xF8, .hi = 0xFF }, .{ .lo = 0x3B1, .hi = 0x3C9 }, .{ .lo = 0x430, .hi = 0x45F } };
const letter = [_]Range{
    .{ .lo = 'A', .hi = 'Z' },       .{ .lo = 'a', .hi = 'z' },       .{ .lo = 0xAA, .hi = 0xAA },       .{ .lo = 0xB5, .hi = 0xB5 },
    .{ .lo = 0xBA, .hi = 0xBA },     .{ .lo = 0xC0, .hi = 0xD6 },     .{ .lo = 0xD8, .hi = 0xF6 },       .{ .lo = 0xF8, .hi = 0x2C1 },
    .{ .lo = 0x370, .hi = 0x3FF },   .{ .lo = 0x400, .hi = 0x481 },   .{ .lo = 0x48A, .hi = 0x52F },     .{ .lo = 0x531, .hi = 0x587 },
    .{ .lo = 0x5D0, .hi = 0x5EA },   .{ .lo = 0x620, .hi = 0x64A },   .{ .lo = 0x671, .hi = 0x6D3 },     .{ .lo = 0x904, .hi = 0x939 },
    .{ .lo = 0xE01, .hi = 0xE30 },   .{ .lo = 0x10A0, .hi = 0x10FF }, .{ .lo = 0x1100, .hi = 0x11FF },   .{ .lo = 0x1E00, .hi = 0x1FFF },
    .{ .lo = 0x3041, .hi = 0x3096 }, .{ .lo = 0x30A1, .hi = 0x30FA }, .{ .lo = 0x3400, .hi = 0x4DBF },   .{ .lo = 0x4E00, .hi = 0x9FFF },
    .{ .lo = 0xAC00, .hi = 0xD7A3 }, .{ .lo = 0xF900, .hi = 0xFAFF }, .{ .lo = 0x20000, .hi = 0x2FFFF },
};
const number = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 0xB2, .hi = 0xB3 }, .{ .lo = 0xB9, .hi = 0xB9 }, .{ .lo = 0xBC, .hi = 0xBE }, .{ .lo = 0x660, .hi = 0x669 }, .{ .lo = 0x6F0, .hi = 0x6F9 }, .{ .lo = 0x966, .hi = 0x96F }, .{ .lo = 0x2160, .hi = 0x2188 }, .{ .lo = 0xFF10, .hi = 0xFF19 } };
const nd = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 0x660, .hi = 0x669 }, .{ .lo = 0x6F0, .hi = 0x6F9 }, .{ .lo = 0x966, .hi = 0x96F }, .{ .lo = 0xFF10, .hi = 0xFF19 } };
const punct = [_]Range{
    .{ .lo = '!', .hi = '#' },       .{ .lo = '%', .hi = '*' },       .{ .lo = ',', .hi = '/' },       .{ .lo = ':', .hi = ';' },
    .{ .lo = '?', .hi = '@' },       .{ .lo = '[', .hi = ']' },       .{ .lo = '_', .hi = '_' },       .{ .lo = '{', .hi = '{' },
    .{ .lo = '}', .hi = '}' },       .{ .lo = 0xA1, .hi = 0xA1 },     .{ .lo = 0xA7, .hi = 0xA7 },     .{ .lo = 0xAB, .hi = 0xAB },
    .{ .lo = 0xB6, .hi = 0xB7 },     .{ .lo = 0xBB, .hi = 0xBB },     .{ .lo = 0xBF, .hi = 0xBF },     .{ .lo = 0x2010, .hi = 0x2027 },
    .{ .lo = 0x2030, .hi = 0x205E }, .{ .lo = 0x3001, .hi = 0x3003 }, .{ .lo = 0x3008, .hi = 0x3011 },
};
const symbol = [_]Range{
    .{ .lo = '$', .hi = '$' },       .{ .lo = '+', .hi = '+' },       .{ .lo = '<', .hi = '>' },         .{ .lo = '^', .hi = '^' },
    .{ .lo = '`', .hi = '`' },       .{ .lo = '|', .hi = '|' },       .{ .lo = '~', .hi = '~' },         .{ .lo = 0xA2, .hi = 0xA6 },
    .{ .lo = 0xA8, .hi = 0xA9 },     .{ .lo = 0xAC, .hi = 0xAC },     .{ .lo = 0xAE, .hi = 0xB1 },       .{ .lo = 0xB4, .hi = 0xB4 },
    .{ .lo = 0xD7, .hi = 0xD7 },     .{ .lo = 0xF7, .hi = 0xF7 },     .{ .lo = 0x20A0, .hi = 0x20C0 },   .{ .lo = 0x2100, .hi = 0x214F },
    .{ .lo = 0x2190, .hi = 0x23FF }, .{ .lo = 0x2500, .hi = 0x27BF }, .{ .lo = 0x1F300, .hi = 0x1FAFF },
};
const zs = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 0xA0, .hi = 0xA0 }, .{ .lo = 0x1680, .hi = 0x1680 }, .{ .lo = 0x2000, .hi = 0x200A }, .{ .lo = 0x202F, .hi = 0x202F }, .{ .lo = 0x205F, .hi = 0x205F }, .{ .lo = 0x3000, .hi = 0x3000 } };
const separator = [_]Range{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = 0xA0, .hi = 0xA0 }, .{ .lo = 0x1680, .hi = 0x1680 }, .{ .lo = 0x2000, .hi = 0x200A }, .{ .lo = 0x2028, .hi = 0x2029 }, .{ .lo = 0x202F, .hi = 0x202F }, .{ .lo = 0x205F, .hi = 0x205F }, .{ .lo = 0x3000, .hi = 0x3000 } };
const control = [_]Range{ .{ .lo = 0, .hi = 0x1F }, .{ .lo = 0x7F, .hi = 0x9F } };
const mark = [_]Range{ .{ .lo = 0x300, .hi = 0x36F }, .{ .lo = 0x483, .hi = 0x489 }, .{ .lo = 0x591, .hi = 0x5BD }, .{ .lo = 0x610, .hi = 0x61A }, .{ .lo = 0x64B, .hi = 0x65F }, .{ .lo = 0x93A, .hi = 0x94F }, .{ .lo = 0x1AB0, .hi = 0x1AFF }, .{ .lo = 0x1DC0, .hi = 0x1DFF }, .{ .lo = 0x20D0, .hi = 0x20FF }, .{ .lo = 0xFE00, .hi = 0xFE0F }, .{ .lo = 0xFE20, .hi = 0xFE2F } };
const latin = [_]Range{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xAA, .hi = 0xAA }, .{ .lo = 0xBA, .hi = 0xBA }, .{ .lo = 0xC0, .hi = 0xD6 }, .{ .lo = 0xD8, .hi = 0xF6 }, .{ .lo = 0xF8, .hi = 0x2B8 }, .{ .lo = 0x1E00, .hi = 0x1EFF }, .{ .lo = 0x2C60, .hi = 0x2C7F }, .{ .lo = 0xA720, .hi = 0xA7FF }, .{ .lo = 0xFF21, .hi = 0xFF3A }, .{ .lo = 0xFF41, .hi = 0xFF5A } };
const greek = [_]Range{ .{ .lo = 0x370, .hi = 0x3FF }, .{ .lo = 0x1F00, .hi = 0x1FFF } };
const cyrillic = [_]Range{ .{ .lo = 0x400, .hi = 0x52F }, .{ .lo = 0x1C80, .hi = 0x1C8F }, .{ .lo = 0x2DE0, .hi = 0x2DFF }, .{ .lo = 0xA640, .hi = 0xA69F } };
const han = [_]Range{ .{ .lo = 0x2E80, .hi = 0x2FD5 }, .{ .lo = 0x3005, .hi = 0x3007 }, .{ .lo = 0x3021, .hi = 0x3029 }, .{ .lo = 0x3400, .hi = 0x4DBF }, .{ .lo = 0x4E00, .hi = 0x9FFF }, .{ .lo = 0xF900, .hi = 0xFAFF }, .{ .lo = 0x20000, .hi = 0x2FFFF } };
const hiragana = [_]Range{.{ .lo = 0x3041, .hi = 0x309F }};
const katakana = [_]Range{ .{ .lo = 0x30A1, .hi = 0x30FF }, .{ .lo = 0x31F0, .hi = 0x31FF }, .{ .lo = 0xFF66, .hi = 0xFF9D } };
const hangul = [_]Range{ .{ .lo = 0x1100, .hi = 0x11FF }, .{ .lo = 0x3131, .hi = 0x318E }, .{ .lo = 0xAC00, .hi = 0xD7A3 } };
const arabic = [_]Range{ .{ .lo = 0x600, .hi = 0x6FF }, .{ .lo = 0x750, .hi = 0x77F }, .{ .lo = 0xFB50, .hi = 0xFDFF }, .{ .lo = 0xFE70, .hi = 0xFEFF } };
const hebrew = [_]Range{ .{ .lo = 0x591, .hi = 0x5F4 }, .{ .lo = 0xFB1D, .hi = 0xFB4F } };
const thai = [_]Range{.{ .lo = 0xE01, .hi = 0xE5B }};
const devanagari = [_]Range{.{ .lo = 0x900, .hi = 0x97F }};
const emoji = [_]Range{ .{ .lo = 0x23, .hi = 0x23 }, .{ .lo = 0x2A, .hi = 0x2A }, .{ .lo = '0', .hi = '9' }, .{ .lo = 0xA9, .hi = 0xA9 }, .{ .lo = 0xAE, .hi = 0xAE }, .{ .lo = 0x203C, .hi = 0x203C }, .{ .lo = 0x2049, .hi = 0x2049 }, .{ .lo = 0x2122, .hi = 0x2122 }, .{ .lo = 0x2139, .hi = 0x2139 }, .{ .lo = 0x2194, .hi = 0x21AA }, .{ .lo = 0x231A, .hi = 0x23FF }, .{ .lo = 0x25AA, .hi = 0x27BF }, .{ .lo = 0x2934, .hi = 0x2935 }, .{ .lo = 0x2B05, .hi = 0x2B55 }, .{ .lo = 0x1F000, .hi = 0x1FAFF } };
const emoji_pres = [_]Range{ .{ .lo = 0x231A, .hi = 0x231B }, .{ .lo = 0x23E9, .hi = 0x23F3 }, .{ .lo = 0x25FD, .hi = 0x27BF }, .{ .lo = 0x2B50, .hi = 0x2B55 }, .{ .lo = 0x1F300, .hi = 0x1FAFF } };
const any_cp = [_]Range{.{ .lo = 0, .hi = 0x10FFFF }};
const ascii_r = [_]Range{.{ .lo = 0, .hi = 0x7F }};

const bidi_control = [_]Range{ .{ .lo = 0x61C, .hi = 0x61C }, .{ .lo = 0x200E, .hi = 0x200F }, .{ .lo = 0x202A, .hi = 0x202E }, .{ .lo = 0x2066, .hi = 0x2069 } };
const format = [_]Range{ .{ .lo = 0xAD, .hi = 0xAD }, .{ .lo = 0x600, .hi = 0x605 }, .{ .lo = 0x61C, .hi = 0x61C }, .{ .lo = 0x6DD, .hi = 0x6DD }, .{ .lo = 0x70F, .hi = 0x70F }, .{ .lo = 0x180E, .hi = 0x180E }, .{ .lo = 0x200B, .hi = 0x200F }, .{ .lo = 0x202A, .hi = 0x202E }, .{ .lo = 0x2060, .hi = 0x2064 }, .{ .lo = 0x2066, .hi = 0x206F }, .{ .lo = 0xFEFF, .hi = 0xFEFF }, .{ .lo = 0xFFF9, .hi = 0xFFFB }, .{ .lo = 0xE0001, .hi = 0xE0001 }, .{ .lo = 0xE0020, .hi = 0xE007F } };
const default_ignorable = [_]Range{ .{ .lo = 0xAD, .hi = 0xAD }, .{ .lo = 0x34F, .hi = 0x34F }, .{ .lo = 0x61C, .hi = 0x61C }, .{ .lo = 0x115F, .hi = 0x1160 }, .{ .lo = 0x17B4, .hi = 0x17B5 }, .{ .lo = 0x180B, .hi = 0x180F }, .{ .lo = 0x200B, .hi = 0x200F }, .{ .lo = 0x202A, .hi = 0x202E }, .{ .lo = 0x2060, .hi = 0x206F }, .{ .lo = 0x3164, .hi = 0x3164 }, .{ .lo = 0xFE00, .hi = 0xFE0F }, .{ .lo = 0xFEFF, .hi = 0xFEFF }, .{ .lo = 0xFFA0, .hi = 0xFFA0 }, .{ .lo = 0xFFF0, .hi = 0xFFF8 }, .{ .lo = 0xE0000, .hi = 0xE0FFF } };
const hex_digit = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'F' }, .{ .lo = 'a', .hi = 'f' }, .{ .lo = 0xFF10, .hi = 0xFF19 }, .{ .lo = 0xFF21, .hi = 0xFF26 }, .{ .lo = 0xFF41, .hi = 0xFF46 } };
const ascii_hex = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'F' }, .{ .lo = 'a', .hi = 'f' } };
const connector = [_]Range{ .{ .lo = '_', .hi = '_' }, .{ .lo = 0x203F, .hi = 0x2040 }, .{ .lo = 0x2054, .hi = 0x2054 }, .{ .lo = 0xFE33, .hi = 0xFE34 }, .{ .lo = 0xFE4D, .hi = 0xFE4F }, .{ .lo = 0xFF3F, .hi = 0xFF3F } };
const dash = [_]Range{ .{ .lo = '-', .hi = '-' }, .{ .lo = 0x58A, .hi = 0x58A }, .{ .lo = 0x2010, .hi = 0x2015 }, .{ .lo = 0x2E3A, .hi = 0x2E3B }, .{ .lo = 0x301C, .hi = 0x301C }, .{ .lo = 0xFE58, .hi = 0xFE58 }, .{ .lo = 0xFF0D, .hi = 0xFF0D } };
const open_punct = [_]Range{ .{ .lo = '(', .hi = '(' }, .{ .lo = '[', .hi = '[' }, .{ .lo = '{', .hi = '{' }, .{ .lo = 0x3008, .hi = 0x3008 }, .{ .lo = 0x300A, .hi = 0x300A }, .{ .lo = 0x300C, .hi = 0x300C } };
const close_punct = [_]Range{ .{ .lo = ')', .hi = ')' }, .{ .lo = ']', .hi = ']' }, .{ .lo = '}', .hi = '}' }, .{ .lo = 0x3009, .hi = 0x3009 }, .{ .lo = 0x300B, .hi = 0x300B }, .{ .lo = 0x300D, .hi = 0x300D } };
const initial_punct = [_]Range{ .{ .lo = 0xAB, .hi = 0xAB }, .{ .lo = 0x2018, .hi = 0x2018 }, .{ .lo = 0x201C, .hi = 0x201C } };
const final_punct = [_]Range{ .{ .lo = 0xBB, .hi = 0xBB }, .{ .lo = 0x2019, .hi = 0x2019 }, .{ .lo = 0x201D, .hi = 0x201D } };
const line_sep = [_]Range{.{ .lo = 0x2028, .hi = 0x2028 }};
const para_sep = [_]Range{.{ .lo = 0x2029, .hi = 0x2029 }};
const surrogate = [_]Range{.{ .lo = 0xD800, .hi = 0xDFFF }};
const private_use = [_]Range{ .{ .lo = 0xE000, .hi = 0xF8FF }, .{ .lo = 0xF0000, .hi = 0x10FFFF } };
const variation = [_]Range{ .{ .lo = 0x180B, .hi = 0x180D }, .{ .lo = 0xFE00, .hi = 0xFE0F }, .{ .lo = 0xE0100, .hi = 0xE01EF } };
const regional = [_]Range{.{ .lo = 0x1F1E6, .hi = 0x1F1FF }};
const emoji_modifier = [_]Range{.{ .lo = 0x1F3FB, .hi = 0x1F3FF }};
const emoji_component = [_]Range{ .{ .lo = '#', .hi = '#' }, .{ .lo = '*', .hi = '*' }, .{ .lo = '0', .hi = '9' }, .{ .lo = 0x200D, .hi = 0x200D }, .{ .lo = 0x20E3, .hi = 0x20E3 }, .{ .lo = 0xFE0F, .hi = 0xFE0F }, .{ .lo = 0x1F1E6, .hi = 0x1F1FF }, .{ .lo = 0x1F3FB, .hi = 0x1F3FF }, .{ .lo = 0xE0020, .hi = 0xE007F } };
const none_cp = [_]Range{};

const PropEntry = struct { []const u8, []const Range };

const prop_table = std.StaticStringMap([]const Range).initComptime([_]PropEntry{
    .{ "L", &letter },                      .{ "Letter", &letter },                    .{ "Alphabetic", &letter }, .{ "Alpha", &letter },
    .{ "ID_Start", &letter },               .{ "ID_Continue", &letter },               .{ "Lu", &lu },             .{ "Uppercase_Letter", &lu },
    .{ "Uppercase", &lu },                  .{ "Upper", &lu },                         .{ "Ll", &ll },             .{ "Lowercase_Letter", &ll },
    .{ "Lowercase", &ll },                  .{ "Lower", &ll },                         .{ "N", &number },          .{ "Number", &number },
    .{ "Nd", &nd },                         .{ "Decimal_Number", &nd },                .{ "digit", &nd },          .{ "P", &punct },
    .{ "Punctuation", &punct },             .{ "punct", &punct },                      .{ "S", &symbol },          .{ "Symbol", &symbol },
    .{ "Sc", &symbol },                     .{ "Sm", &symbol },                        .{ "So", &symbol },         .{ "Sk", &symbol },
    .{ "Z", &separator },                   .{ "Separator", &separator },              .{ "Zs", &zs },             .{ "Space_Separator", &zs },
    .{ "White_Space", &space_ranges },      .{ "space", &space_ranges },               .{ "Cc", &control },        .{ "Control", &control },
    .{ "C", &control },                     .{ "Other", &control },                    .{ "M", &mark },            .{ "Mark", &mark },
    .{ "Mn", &mark },                       .{ "Combining_Mark", &mark },              .{ "Latin", &latin },       .{ "Latn", &latin },
    .{ "Greek", &greek },                   .{ "Grek", &greek },                       .{ "Cyrillic", &cyrillic }, .{ "Cyrl", &cyrillic },
    .{ "Han", &han },                       .{ "Hani", &han },                         .{ "Hiragana", &hiragana }, .{ "Hira", &hiragana },
    .{ "Katakana", &katakana },             .{ "Kana", &katakana },                    .{ "Hangul", &hangul },     .{ "Hang", &hangul },
    .{ "Arabic", &arabic },                 .{ "Arab", &arabic },                      .{ "Hebrew", &hebrew },     .{ "Hebr", &hebrew },
    .{ "Thai", &thai },                     .{ "Devanagari", &devanagari },            .{ "Deva", &devanagari },   .{ "Emoji", &emoji },
    .{ "Emoji_Presentation", &emoji_pres }, .{ "Extended_Pictographic", &emoji_pres }, .{ "Any", &any_cp },        .{ "ASCII", &ascii_r },
    .{ "Bidi_Control", &bidi_control },     .{ "Bidi_C", &bidi_control },              .{ "Cf", &format },         .{ "Format", &format },
    .{ "Default_Ignorable_Code_Point", &default_ignorable }, .{ "DI", &default_ignorable },
    .{ "Hex_Digit", &hex_digit },           .{ "Hex", &hex_digit },                    .{ "ASCII_Hex_Digit", &ascii_hex }, .{ "AHex", &ascii_hex },
    .{ "Pc", &connector },                  .{ "Connector_Punctuation", &connector },  .{ "Pd", &dash },           .{ "Dash_Punctuation", &dash },
    .{ "Dash", &dash },                     .{ "Ps", &open_punct },                    .{ "Open_Punctuation", &open_punct }, .{ "Pe", &close_punct },
    .{ "Close_Punctuation", &close_punct }, .{ "Pi", &initial_punct },                 .{ "Initial_Punctuation", &initial_punct }, .{ "Pf", &final_punct },
    .{ "Final_Punctuation", &final_punct }, .{ "Po", &punct },                         .{ "Other_Punctuation", &punct }, .{ "Zl", &line_sep },
    .{ "Line_Separator", &line_sep },       .{ "Zp", &para_sep },                      .{ "Paragraph_Separator", &para_sep }, .{ "Cs", &surrogate },
    .{ "Surrogate", &surrogate },           .{ "Co", &private_use },                   .{ "Private_Use", &private_use }, .{ "Mc", &mark },
    .{ "Spacing_Mark", &mark },             .{ "Me", &mark },                          .{ "Enclosing_Mark", &mark }, .{ "Nonspacing_Mark", &mark },
    .{ "Lt", &none_cp },                    .{ "Titlecase_Letter", &none_cp },         .{ "Lm", &letter },         .{ "Modifier_Letter", &letter },
    .{ "Lo", &letter },                     .{ "Other_Letter", &letter },              .{ "LC", &letter },         .{ "Cased_Letter", &letter },
    .{ "Nl", &number },                     .{ "Letter_Number", &number },             .{ "No", &number },         .{ "Other_Number", &number },
    .{ "Math_Symbol", &symbol },            .{ "Currency_Symbol", &symbol },           .{ "Modifier_Symbol", &symbol }, .{ "Other_Symbol", &symbol },
    .{ "Cn", &none_cp },                    .{ "Unassigned", &none_cp },               .{ "Assigned", &any_cp },   .{ "Variation_Selector", &variation },
    .{ "VS", &variation },                  .{ "Regional_Indicator", &regional },      .{ "RI", &regional },       .{ "Emoji_Modifier", &emoji_modifier },
    .{ "EMod", &emoji_modifier },           .{ "Emoji_Component", &emoji_component },  .{ "EComp", &emoji_component }, .{ "Emoji_Modifier_Base", &emoji_pres },
    .{ "EBase", &emoji_pres },              .{ "ExtPict", &emoji_pres },               .{ "EPres", &emoji_pres },  .{ "XID_Start", &letter },
    .{ "XIDS", &letter },                   .{ "XID_Continue", &letter },              .{ "XIDC", &letter },       .{ "IDS", &letter },
    .{ "IDC", &letter },                    .{ "Cased", &letter },                     .{ "Case_Ignorable", &mark }, .{ "CI", &mark },
    .{ "Diacritic", &mark },                .{ "Dia", &mark },                         .{ "Extender", &none_cp },  .{ "Ideographic", &han },
    .{ "Ideo", &han },                      .{ "Unified_Ideograph", &han },            .{ "Math", &symbol },       .{ "Quotation_Mark", &none_cp },
    .{ "Pattern_White_Space", &space_ranges }, .{ "Pat_WS", &space_ranges },           .{ "Pattern_Syntax", &punct }, .{ "Pat_Syn", &punct },
    .{ "Noncharacter_Code_Point", &none_cp }, .{ "NChar", &none_cp },                  .{ "Grapheme_Base", &letter }, .{ "Gr_Base", &letter },
    .{ "Grapheme_Extend", &mark },          .{ "Gr_Ext", &mark },                      .{ "Sentence_Terminal", &punct }, .{ "Terminal_Punctuation", &punct },
});

/// Adds a \p{...} set by name, General_Category= and Script= forms included. False if unknown.
pub fn addProperty(l: *List, a: Allocator, name_in: []const u8) Allocator.Error!bool {
    var name = name_in;
    if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
        const lhs = name[0..eq];
        const known = std.mem.eql(u8, lhs, "General_Category") or std.mem.eql(u8, lhs, "gc") or std.mem.eql(u8, lhs, "Script") or
            std.mem.eql(u8, lhs, "sc") or std.mem.eql(u8, lhs, "Script_Extensions") or std.mem.eql(u8, lhs, "scx");
        if (!known) return false;
        name = name[eq + 1 ..];
        // A script with no table here is empty, not an error: a bundle's one
        // pattern shouldn't stop its whole script from loading.
        const script = lhs[0] == 'S' or lhs[0] == 's';
        if (script and prop_table.get(name) == null) return true;
    }
    const rs = prop_table.get(name) orelse return false;
    try addAll(l, a, rs);
    return true;
}

/// Simple lowercase mapping: ASCII, Latin-1, Greek and Cyrillic, plus Latin Extended pairs.
pub fn toLower(c: u32) u32 {
    if (c < 0x80) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 32;
    if (c >= 0x100 and c <= 0x17F) {
        if (c == 0x130 or c == 0x131 or c == 0x138 or c == 0x149 or c == 0x178 or c == 0x17F) {
            return if (c == 0x178) 0xFF else c;
        }
        const odd_is_upper = (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E);
        if (odd_is_upper) return if (c & 1 == 1) c + 1 else c;
        return if (c & 1 == 0) c + 1 else c;
    }
    if (c >= 0x391 and c <= 0x3A9 and c != 0x3A2) return c + 32;
    if (c >= 0x400 and c <= 0x40F) return c + 80;
    if (c >= 0x410 and c <= 0x42F) return c + 32;
    if (c >= 0x460 and c <= 0x52F and !(c >= 0x482 and c <= 0x489)) return if (c & 1 == 0) c + 1 else c;
    if (c >= 0x531 and c <= 0x556) return c + 48;
    if (c >= 0x1E00 and c <= 0x1EFF) return if (c & 1 == 0) c + 1 else c;
    if (c >= 0xFF21 and c <= 0xFF3A) return c + 32;
    return c;
}

/// Simple uppercase mapping, the inverse of toLower where one exists.
pub fn toUpper(c: u32) u32 {
    if (c < 0x80) return if (c >= 'a' and c <= 'z') c - 32 else c;
    if (c == 0xB5) return 0x39C;
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 32;
    if (c == 0xFF) return 0x178;
    if (c >= 0x100 and c <= 0x17F) {
        if (c == 0x130 or c == 0x131 or c == 0x138 or c == 0x149 or c == 0x178) return if (c == 0x131) 'I' else c;
        if (c == 0x17F) return 'S';
        const odd_is_upper = (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E);
        if (odd_is_upper) return if (c & 1 == 0) c - 1 else c;
        return if (c & 1 == 1) c - 1 else c;
    }
    if (c >= 0x3B1 and c <= 0x3C9 and c != 0x3C2) return c - 32;
    if (c == 0x3C2) return 0x3A3;
    if (c >= 0x450 and c <= 0x45F) return c - 80;
    if (c >= 0x430 and c <= 0x44F) return c - 32;
    if (c >= 0x460 and c <= 0x52F and !(c >= 0x482 and c <= 0x489)) return if (c & 1 == 1) c - 1 else c;
    if (c >= 0x561 and c <= 0x586) return c - 48;
    if (c >= 0x1E00 and c <= 0x1EFF) return if (c & 1 == 1) c - 1 else c;
    if (c >= 0xFF41 and c <= 0xFF5A) return c - 32;
    return c;
}
