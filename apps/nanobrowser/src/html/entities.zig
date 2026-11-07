//! The named character references pages really use: all of HTML4's, the
//! HTML5 names that turn up in the wild, and which of them work without a
//! semicolon. Not the full 2231-entry HTML5 table.
const std = @import("std");

const E = struct { []const u8, u21 };

const table = std.StaticStringMap(u21).initComptime([_]E{
    // HTML 4: Latin-1.
    .{ "nbsp", 160 },         .{ "iexcl", 161 },           .{ "cent", 162 },             .{ "pound", 163 },
    .{ "curren", 164 },       .{ "yen", 165 },             .{ "brvbar", 166 },           .{ "sect", 167 },
    .{ "uml", 168 },          .{ "copy", 169 },            .{ "ordf", 170 },             .{ "laquo", 171 },
    .{ "not", 172 },          .{ "shy", 173 },             .{ "reg", 174 },              .{ "macr", 175 },
    .{ "deg", 176 },          .{ "plusmn", 177 },          .{ "sup2", 178 },             .{ "sup3", 179 },
    .{ "acute", 180 },        .{ "micro", 181 },           .{ "para", 182 },             .{ "middot", 183 },
    .{ "cedil", 184 },        .{ "sup1", 185 },            .{ "ordm", 186 },             .{ "raquo", 187 },
    .{ "frac14", 188 },       .{ "frac12", 189 },          .{ "frac34", 190 },           .{ "iquest", 191 },
    .{ "Agrave", 192 },       .{ "Aacute", 193 },          .{ "Acirc", 194 },            .{ "Atilde", 195 },
    .{ "Auml", 196 },         .{ "Aring", 197 },           .{ "AElig", 198 },            .{ "Ccedil", 199 },
    .{ "Egrave", 200 },       .{ "Eacute", 201 },          .{ "Ecirc", 202 },            .{ "Euml", 203 },
    .{ "Igrave", 204 },       .{ "Iacute", 205 },          .{ "Icirc", 206 },            .{ "Iuml", 207 },
    .{ "ETH", 208 },          .{ "Ntilde", 209 },          .{ "Ograve", 210 },           .{ "Oacute", 211 },
    .{ "Ocirc", 212 },        .{ "Otilde", 213 },          .{ "Ouml", 214 },             .{ "times", 215 },
    .{ "Oslash", 216 },       .{ "Ugrave", 217 },          .{ "Uacute", 218 },           .{ "Ucirc", 219 },
    .{ "Uuml", 220 },         .{ "Yacute", 221 },          .{ "THORN", 222 },            .{ "szlig", 223 },
    .{ "agrave", 224 },       .{ "aacute", 225 },          .{ "acirc", 226 },            .{ "atilde", 227 },
    .{ "auml", 228 },         .{ "aring", 229 },           .{ "aelig", 230 },            .{ "ccedil", 231 },
    .{ "egrave", 232 },       .{ "eacute", 233 },          .{ "ecirc", 234 },            .{ "euml", 235 },
    .{ "igrave", 236 },       .{ "iacute", 237 },          .{ "icirc", 238 },            .{ "iuml", 239 },
    .{ "eth", 240 },          .{ "ntilde", 241 },          .{ "ograve", 242 },           .{ "oacute", 243 },
    .{ "ocirc", 244 },        .{ "otilde", 245 },          .{ "ouml", 246 },             .{ "divide", 247 },
    .{ "oslash", 248 },       .{ "ugrave", 249 },          .{ "uacute", 250 },           .{ "ucirc", 251 },
    .{ "uuml", 252 },         .{ "yacute", 253 },          .{ "thorn", 254 },            .{ "yuml", 255 },
    // HTML 4: special.
    .{ "quot", 34 },          .{ "amp", 38 },              .{ "lt", 60 },                .{ "gt", 62 },
    .{ "OElig", 338 },        .{ "oelig", 339 },           .{ "Scaron", 352 },           .{ "scaron", 353 },
    .{ "Yuml", 376 },         .{ "circ", 710 },            .{ "tilde", 732 },            .{ "ensp", 8194 },
    .{ "emsp", 8195 },        .{ "thinsp", 8201 },         .{ "zwnj", 8204 },            .{ "zwj", 8205 },
    .{ "lrm", 8206 },         .{ "rlm", 8207 },            .{ "ndash", 8211 },           .{ "mdash", 8212 },
    .{ "lsquo", 8216 },       .{ "rsquo", 8217 },          .{ "sbquo", 8218 },           .{ "ldquo", 8220 },
    .{ "rdquo", 8221 },       .{ "bdquo", 8222 },          .{ "dagger", 8224 },          .{ "Dagger", 8225 },
    .{ "permil", 8240 },      .{ "lsaquo", 8249 },         .{ "rsaquo", 8250 },          .{ "euro", 8364 },
    // HTML 4: symbols and Greek.
    .{ "fnof", 402 },         .{ "Alpha", 913 },           .{ "Beta", 914 },             .{ "Gamma", 915 },
    .{ "Delta", 916 },        .{ "Epsilon", 917 },         .{ "Zeta", 918 },             .{ "Eta", 919 },
    .{ "Theta", 920 },        .{ "Iota", 921 },            .{ "Kappa", 922 },            .{ "Lambda", 923 },
    .{ "Mu", 924 },           .{ "Nu", 925 },              .{ "Xi", 926 },               .{ "Omicron", 927 },
    .{ "Pi", 928 },           .{ "Rho", 929 },             .{ "Sigma", 931 },            .{ "Tau", 932 },
    .{ "Upsilon", 933 },      .{ "Phi", 934 },             .{ "Chi", 935 },              .{ "Psi", 936 },
    .{ "Omega", 937 },        .{ "alpha", 945 },           .{ "beta", 946 },             .{ "gamma", 947 },
    .{ "delta", 948 },        .{ "epsilon", 949 },         .{ "zeta", 950 },             .{ "eta", 951 },
    .{ "theta", 952 },        .{ "iota", 953 },            .{ "kappa", 954 },            .{ "lambda", 955 },
    .{ "mu", 956 },           .{ "nu", 957 },              .{ "xi", 958 },               .{ "omicron", 959 },
    .{ "pi", 960 },           .{ "rho", 961 },             .{ "sigmaf", 962 },           .{ "sigma", 963 },
    .{ "tau", 964 },          .{ "upsilon", 965 },         .{ "phi", 966 },              .{ "chi", 967 },
    .{ "psi", 968 },          .{ "omega", 969 },           .{ "thetasym", 977 },         .{ "upsih", 978 },
    .{ "piv", 982 },          .{ "bull", 8226 },           .{ "hellip", 8230 },          .{ "prime", 8242 },
    .{ "Prime", 8243 },       .{ "oline", 8254 },          .{ "frasl", 8260 },           .{ "weierp", 8472 },
    .{ "image", 8465 },       .{ "real", 8476 },           .{ "trade", 8482 },           .{ "alefsym", 8501 },
    .{ "larr", 8592 },        .{ "uarr", 8593 },           .{ "rarr", 8594 },            .{ "darr", 8595 },
    .{ "harr", 8596 },        .{ "crarr", 8629 },          .{ "lArr", 8656 },            .{ "uArr", 8657 },
    .{ "rArr", 8658 },        .{ "dArr", 8659 },           .{ "hArr", 8660 },            .{ "forall", 8704 },
    .{ "part", 8706 },        .{ "exist", 8707 },          .{ "empty", 8709 },           .{ "nabla", 8711 },
    .{ "isin", 8712 },        .{ "notin", 8713 },          .{ "ni", 8715 },              .{ "prod", 8719 },
    .{ "sum", 8721 },         .{ "minus", 8722 },          .{ "lowast", 8727 },          .{ "radic", 8730 },
    .{ "prop", 8733 },        .{ "infin", 8734 },          .{ "ang", 8736 },             .{ "and", 8743 },
    .{ "or", 8744 },          .{ "cap", 8745 },            .{ "cup", 8746 },             .{ "int", 8747 },
    .{ "there4", 8756 },      .{ "sim", 8764 },            .{ "cong", 8773 },            .{ "asymp", 8776 },
    .{ "ne", 8800 },          .{ "equiv", 8801 },          .{ "le", 8804 },              .{ "ge", 8805 },
    .{ "sub", 8834 },         .{ "sup", 8835 },            .{ "nsub", 8836 },            .{ "sube", 8838 },
    .{ "supe", 8839 },        .{ "oplus", 8853 },          .{ "otimes", 8855 },          .{ "perp", 8869 },
    .{ "sdot", 8901 },        .{ "lceil", 8968 },          .{ "rceil", 8969 },           .{ "lfloor", 8970 },
    .{ "rfloor", 8971 },      .{ "lang", 10216 },          .{ "rang", 10217 },           .{ "loz", 9674 },
    .{ "spades", 9824 },      .{ "clubs", 9827 },          .{ "hearts", 9829 },          .{ "diams", 9830 },
    // HTML 5 names pages use.
    .{ "apos", 39 },          .{ "AMP", 38 },              .{ "LT", 60 },                .{ "GT", 62 },
    .{ "QUOT", 34 },          .{ "COPY", 169 },            .{ "REG", 174 },              .{ "TRADE", 8482 },
    .{ "NewLine", 10 },       .{ "Tab", 9 },               .{ "excl", 33 },              .{ "num", 35 },
    .{ "dollar", 36 },        .{ "percnt", 37 },           .{ "lpar", 40 },              .{ "rpar", 41 },
    .{ "ast", 42 },           .{ "plus", 43 },             .{ "comma", 44 },             .{ "period", 46 },
    .{ "sol", 47 },           .{ "colon", 58 },            .{ "semi", 59 },              .{ "equals", 61 },
    .{ "quest", 63 },         .{ "commat", 64 },           .{ "lsqb", 91 },              .{ "lbrack", 91 },
    .{ "bsol", 92 },          .{ "rsqb", 93 },             .{ "rbrack", 93 },            .{ "Hat", 94 },
    .{ "lowbar", 95 },        .{ "grave", 96 },            .{ "lcub", 123 },             .{ "lbrace", 123 },
    .{ "verbar", 124 },       .{ "vert", 124 },            .{ "rcub", 125 },             .{ "rbrace", 125 },
    .{ "hyphen", 8208 },      .{ "dash", 8208 },           .{ "horbar", 8213 },          .{ "lsquor", 8218 },
    .{ "ldquor", 8222 },      .{ "bullet", 8226 },         .{ "mldr", 8230 },            .{ "nldr", 8229 },
    .{ "numsp", 8199 },       .{ "puncsp", 8200 },         .{ "hairsp", 8202 },          .{ "emsp13", 8196 },
    .{ "emsp14", 8197 },      .{ "ZeroWidthSpace", 8203 }, .{ "NonBreakingSpace", 160 }, .{ "nobreak", 8288 },
    .{ "check", 10003 },      .{ "checkmark", 10003 },     .{ "cross", 10007 },          .{ "star", 9734 },
    .{ "starf", 9733 },       .{ "bigstar", 9733 },        .{ "phone", 9742 },           .{ "female", 9792 },
    .{ "male", 9794 },        .{ "sung", 9834 },           .{ "flat", 9837 },            .{ "natural", 9838 },
    .{ "sharp", 9839 },       .{ "malt", 10016 },          .{ "maltese", 10016 },        .{ "sext", 10038 },
    .{ "copysr", 8471 },      .{ "numero", 8470 },         .{ "incare", 8453 },          .{ "ohm", 937 },
    .{ "half", 189 },         .{ "frac13", 8531 },         .{ "frac23", 8532 },          .{ "frac15", 8533 },
    .{ "frac25", 8534 },      .{ "frac35", 8535 },         .{ "frac45", 8536 },          .{ "frac16", 8537 },
    .{ "frac56", 8538 },      .{ "frac18", 8539 },         .{ "frac38", 8540 },          .{ "frac58", 8541 },
    .{ "frac78", 8542 },      .{ "rightarrow", 8594 },     .{ "leftarrow", 8592 },       .{ "uparrow", 8593 },
    .{ "downarrow", 8595 },   .{ "leftrightarrow", 8596 }, .{ "RightArrow", 8594 },      .{ "LeftArrow", 8592 },
    .{ "UpArrow", 8593 },     .{ "DownArrow", 8595 },      .{ "Rightarrow", 8658 },      .{ "Leftarrow", 8656 },
    .{ "nearr", 8599 },       .{ "searr", 8600 },          .{ "swarr", 8601 },           .{ "nwarr", 8598 },
    .{ "map", 8614 },         .{ "hookrightarrow", 8618 }, .{ "hookleftarrow", 8617 },   .{ "larrhk", 8617 },
    .{ "rarrhk", 8618 },      .{ "approx", 8776 },         .{ "ap", 8776 },              .{ "leq", 8804 },
    .{ "geq", 8805 },         .{ "neq", 8800 },            .{ "pm", 177 },               .{ "mp", 8723 },
    .{ "setminus", 8726 },    .{ "compfn", 8728 },         .{ "infintie", 10717 },       .{ "subset", 8834 },
    .{ "supset", 8835 },      .{ "emptyset", 8709 },       .{ "varnothing", 8709 },      .{ "in", 8712 },
    .{ "isinv", 8712 },       .{ "hbar", 8463 },           .{ "planck", 8463 },          .{ "ell", 8467 },
    .{ "wp", 8472 },          .{ "Re", 8476 },             .{ "Im", 8465 },              .{ "aleph", 8501 },
    .{ "beth", 8502 },        .{ "angle", 8736 },          .{ "angmsd", 8737 },          .{ "square", 9633 },
    .{ "squ", 9633 },         .{ "squf", 9642 },           .{ "blacksquare", 9642 },     .{ "utri", 9653 },
    .{ "dtri", 9663 },        .{ "ltri", 9667 },           .{ "rtri", 9657 },            .{ "utrif", 9652 },
    .{ "dtrif", 9662 },       .{ "ltrif", 9666 },          .{ "rtrif", 9656 },           .{ "cir", 9675 },
    .{ "bigcirc", 9711 },     .{ "lozenge", 9674 },        .{ "lozf", 10731 },           .{ "spadesuit", 9824 },
    .{ "clubsuit", 9827 },    .{ "heartsuit", 9829 },      .{ "diamondsuit", 9830 },     .{ "langle", 10216 },
    .{ "rangle", 10217 },     .{ "boxh", 9472 },           .{ "boxv", 9474 },            .{ "block", 9608 },
    .{ "blk14", 9617 },       .{ "blk12", 9618 },          .{ "blk34", 9619 },           .{ "Scedil", 350 },
    .{ "scedil", 351 },       .{ "Ccaron", 268 },          .{ "ccaron", 269 },           .{ "Zcaron", 381 },
    .{ "zcaron", 382 },       .{ "Rcaron", 344 },          .{ "rcaron", 345 },           .{ "Lstrok", 321 },
    .{ "lstrok", 322 },       .{ "Nacute", 323 },          .{ "nacute", 324 },           .{ "Sacute", 346 },
    .{ "sacute", 347 },       .{ "Zacute", 377 },          .{ "zacute", 378 },           .{ "Cacute", 262 },
    .{ "cacute", 263 },       .{ "Abreve", 258 },          .{ "abreve", 259 },           .{ "Aogon", 260 },
    .{ "aogon", 261 },        .{ "Eogon", 280 },           .{ "eogon", 281 },            .{ "Gbreve", 286 },
    .{ "gbreve", 287 },       .{ "Idot", 304 },            .{ "imath", 305 },            .{ "inodot", 305 },
    .{ "Dstrok", 272 },       .{ "dstrok", 273 },          .{ "Ecaron", 282 },           .{ "ecaron", 283 },
    .{ "Amacr", 256 },        .{ "amacr", 257 },           .{ "Emacr", 274 },            .{ "emacr", 275 },
    .{ "Imacr", 298 },        .{ "imacr", 299 },           .{ "Omacr", 332 },            .{ "omacr", 333 },
    .{ "Umacr", 362 },        .{ "umacr", 363 },           .{ "breve", 728 },            .{ "caron", 711 },
    .{ "dot", 729 },          .{ "ring", 730 },            .{ "ogon", 731 },             .{ "dblac", 733 },
    .{ "varepsilon", 949 },   .{ "epsi", 949 },            .{ "varphi", 981 },           .{ "straightphi", 981 },
    .{ "varpi", 982 },        .{ "vartheta", 977 },        .{ "varrho", 1009 },          .{ "varsigma", 962 },
    .{ "ic", 8291 },          .{ "it", 8290 },             .{ "af", 8289 },              .{ "ThinSpace", 8201 },
    .{ "MediumSpace", 8287 }, .{ "VeryThinSpace", 8202 },  .{ "InvisibleTimes", 8290 },  .{ "centerdot", 183 },
    .{ "CenterDot", 183 },    .{ "bigtriangleup", 9651 },  .{ "bigtriangledown", 9661 },
});

/// The names that also work with no semicolon.
const legacy = std.StaticStringMap(u21).initComptime([_]E{
    .{ "AElig", 198 },  .{ "AMP", 38 },     .{ "Aacute", 193 }, .{ "Acirc", 194 },  .{ "Agrave", 192 },
    .{ "Aring", 197 },  .{ "Atilde", 195 }, .{ "Auml", 196 },   .{ "COPY", 169 },   .{ "Ccedil", 199 },
    .{ "ETH", 208 },    .{ "Eacute", 201 }, .{ "Ecirc", 202 },  .{ "Egrave", 200 }, .{ "Euml", 203 },
    .{ "GT", 62 },      .{ "Iacute", 205 }, .{ "Icirc", 206 },  .{ "Igrave", 204 }, .{ "Iuml", 207 },
    .{ "LT", 60 },      .{ "Ntilde", 209 }, .{ "Oacute", 211 }, .{ "Ocirc", 212 },  .{ "Ograve", 210 },
    .{ "Oslash", 216 }, .{ "Otilde", 213 }, .{ "Ouml", 214 },   .{ "QUOT", 34 },    .{ "REG", 174 },
    .{ "THORN", 222 },  .{ "Uacute", 218 }, .{ "Ucirc", 219 },  .{ "Ugrave", 217 }, .{ "Uuml", 220 },
    .{ "Yacute", 221 }, .{ "aacute", 225 }, .{ "acirc", 226 },  .{ "acute", 180 },  .{ "aelig", 230 },
    .{ "agrave", 224 }, .{ "amp", 38 },     .{ "aring", 229 },  .{ "atilde", 227 }, .{ "auml", 228 },
    .{ "brvbar", 166 }, .{ "ccedil", 231 }, .{ "cedil", 184 },  .{ "cent", 162 },   .{ "copy", 169 },
    .{ "curren", 164 }, .{ "deg", 176 },    .{ "divide", 247 }, .{ "eacute", 233 }, .{ "ecirc", 234 },
    .{ "egrave", 232 }, .{ "eth", 240 },    .{ "euml", 235 },   .{ "frac12", 189 }, .{ "frac14", 188 },
    .{ "frac34", 190 }, .{ "gt", 62 },      .{ "iacute", 237 }, .{ "icirc", 238 },  .{ "iexcl", 161 },
    .{ "igrave", 236 }, .{ "iquest", 191 }, .{ "iuml", 239 },   .{ "laquo", 171 },  .{ "lt", 60 },
    .{ "macr", 175 },   .{ "micro", 181 },  .{ "middot", 183 }, .{ "nbsp", 160 },   .{ "not", 172 },
    .{ "ntilde", 241 }, .{ "oacute", 243 }, .{ "ocirc", 244 },  .{ "ograve", 242 }, .{ "ordf", 170 },
    .{ "ordm", 186 },   .{ "oslash", 248 }, .{ "otilde", 245 }, .{ "ouml", 246 },   .{ "para", 182 },
    .{ "plusmn", 177 }, .{ "pound", 163 },  .{ "quot", 34 },    .{ "raquo", 187 },  .{ "reg", 174 },
    .{ "sect", 167 },   .{ "shy", 173 },    .{ "sup1", 185 },   .{ "sup2", 178 },   .{ "sup3", 179 },
    .{ "szlig", 223 },  .{ "thorn", 254 },  .{ "times", 215 },  .{ "uacute", 250 }, .{ "ucirc", 251 },
    .{ "ugrave", 249 }, .{ "uml", 168 },    .{ "uuml", 252 },   .{ "yacute", 253 }, .{ "yen", 165 },
    .{ "yuml", 255 },
});

/// The longest a legacy name runs; bounds the prefix search.
pub const legacy_max = 6;

/// The code point of a name written with its semicolon.
pub fn lookup(name: []const u8) ?u21 {
    return table.get(name);
}

/// The code point of a name usable without a semicolon.
pub fn lookupLegacy(name: []const u8) ?u21 {
    return legacy.get(name);
}

/// How many names the table holds, for a test.
pub fn count() usize {
    return table.keys().len;
}
