//! Foreign content: SVG and MathML inside HTML. Names keep their case-adjusted
//! forms (`linearGradient`, `viewBox`); the tokenizer lowercased them all.
const std = @import("std");
const tree = @import("tree.zig");
const tags = @import("tags.zig");
const tz = @import("tokenizer.zig");

const Builder = tree.Builder;
const Token = tree.Token;
const Act = tree.Act;
const Error = tree.Error;

const svg_tags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "altglyph", "altGlyph" },                     .{ "altglyphdef", "altGlyphDef" },
    .{ "altglyphitem", "altGlyphItem" },             .{ "animatecolor", "animateColor" },
    .{ "animatemotion", "animateMotion" },           .{ "animatetransform", "animateTransform" },
    .{ "clippath", "clipPath" },                     .{ "feblend", "feBlend" },
    .{ "fecolormatrix", "feColorMatrix" },           .{ "fecomponenttransfer", "feComponentTransfer" },
    .{ "fecomposite", "feComposite" },               .{ "feconvolvematrix", "feConvolveMatrix" },
    .{ "fediffuselighting", "feDiffuseLighting" },   .{ "fedisplacementmap", "feDisplacementMap" },
    .{ "fedistantlight", "feDistantLight" },         .{ "fedropshadow", "feDropShadow" },
    .{ "feflood", "feFlood" },                       .{ "fefunca", "feFuncA" },
    .{ "fefuncb", "feFuncB" },                       .{ "fefuncg", "feFuncG" },
    .{ "fefuncr", "feFuncR" },                       .{ "fegaussianblur", "feGaussianBlur" },
    .{ "feimage", "feImage" },                       .{ "femerge", "feMerge" },
    .{ "femergenode", "feMergeNode" },               .{ "femorphology", "feMorphology" },
    .{ "feoffset", "feOffset" },                     .{ "fepointlight", "fePointLight" },
    .{ "fespecularlighting", "feSpecularLighting" }, .{ "fespotlight", "feSpotLight" },
    .{ "fetile", "feTile" },                         .{ "feturbulence", "feTurbulence" },
    .{ "foreignobject", "foreignObject" },           .{ "glyphref", "glyphRef" },
    .{ "lineargradient", "linearGradient" },         .{ "radialgradient", "radialGradient" },
    .{ "textpath", "textPath" },
});

const svg_attrs = std.StaticStringMap([]const u8).initComptime(.{
    .{ "attributename", "attributeName" },             .{ "attributetype", "attributeType" },
    .{ "basefrequency", "baseFrequency" },             .{ "baseprofile", "baseProfile" },
    .{ "calcmode", "calcMode" },                       .{ "clippathunits", "clipPathUnits" },
    .{ "diffuseconstant", "diffuseConstant" },         .{ "edgemode", "edgeMode" },
    .{ "filterunits", "filterUnits" },                 .{ "glyphref", "glyphRef" },
    .{ "gradienttransform", "gradientTransform" },     .{ "gradientunits", "gradientUnits" },
    .{ "kernelmatrix", "kernelMatrix" },               .{ "kernelunitlength", "kernelUnitLength" },
    .{ "keypoints", "keyPoints" },                     .{ "keysplines", "keySplines" },
    .{ "keytimes", "keyTimes" },                       .{ "lengthadjust", "lengthAdjust" },
    .{ "limitingconeangle", "limitingConeAngle" },     .{ "markerheight", "markerHeight" },
    .{ "markerunits", "markerUnits" },                 .{ "markerwidth", "markerWidth" },
    .{ "maskcontentunits", "maskContentUnits" },       .{ "maskunits", "maskUnits" },
    .{ "numoctaves", "numOctaves" },                   .{ "pathlength", "pathLength" },
    .{ "patterncontentunits", "patternContentUnits" }, .{ "patterntransform", "patternTransform" },
    .{ "patternunits", "patternUnits" },               .{ "pointsatx", "pointsAtX" },
    .{ "pointsaty", "pointsAtY" },                     .{ "pointsatz", "pointsAtZ" },
    .{ "preservealpha", "preserveAlpha" },             .{ "preserveaspectratio", "preserveAspectRatio" },
    .{ "primitiveunits", "primitiveUnits" },           .{ "refx", "refX" },
    .{ "refy", "refY" },                               .{ "repeatcount", "repeatCount" },
    .{ "repeatdur", "repeatDur" },                     .{ "requiredextensions", "requiredExtensions" },
    .{ "requiredfeatures", "requiredFeatures" },       .{ "specularconstant", "specularConstant" },
    .{ "specularexponent", "specularExponent" },       .{ "spreadmethod", "spreadMethod" },
    .{ "startoffset", "startOffset" },                 .{ "stddeviation", "stdDeviation" },
    .{ "stitchtiles", "stitchTiles" },                 .{ "surfacescale", "surfaceScale" },
    .{ "systemlanguage", "systemLanguage" },           .{ "tablevalues", "tableValues" },
    .{ "targetx", "targetX" },                         .{ "targety", "targetY" },
    .{ "textlength", "textLength" },                   .{ "viewbox", "viewBox" },
    .{ "viewtarget", "viewTarget" },                   .{ "xchannelselector", "xChannelSelector" },
    .{ "ychannelselector", "yChannelSelector" },       .{ "zoomandpan", "zoomAndPan" },
});

/// The foreign attributes the spec names keep their prefixes as they are
/// written, which the flat `Attr` holds as is.
pub fn adjustForeignAttrs(_: *tz.Tag) void {}

pub fn adjustSvgAttrs(t: *tz.Tag) void {
    for (t.attrs) |*a| if (svg_attrs.get(a.name)) |to| {
        a.name = to;
    };
}

pub fn adjustMathAttrs(t: *tz.Tag) void {
    for (t.attrs) |*a| if (std.mem.eql(u8, a.name, "definitionurl")) {
        a.name = "definitionURL";
    };
}

pub fn process(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            try b.insertText(s);
            if (!tree.allWs(s)) b.frameset_ok = false;
        },
        .comment => |s| try b.insertComment(s, null),
        .doctype => {},
        .eof => return b.html(t),
        .start_tag => |*s| {
            if (breaksOut(s)) {
                popToHtml(b);
                return b.html(t);
            }
            try startOther(b, s);
        },
        .end_tag => |*s| {
            if (s.id == .br or s.id == .p) {
                popToHtml(b);
                return b.html(t);
            }
            return endOther(b, t, s);
        },
    }
    return .done;
}

fn breaksOut(s: *const tz.Tag) bool {
    if (tags.breaksForeign(s.id) or tags.breaksForeignName(s.name)) return true;
    if (s.id == .font) return s.attr("color") != null or s.attr("face") != null or s.attr("size") != null;
    return false;
}

fn popToHtml(b: *Builder) void {
    while (b.open.items.len > 1) {
        const c = b.current().?;
        if (c.node.ns == .html or tags.isMathText(c.id) or tree.isHtmlIntegration(c)) return;
        b.pop();
    }
}

fn startOther(b: *Builder, s: *tz.Tag) Error!void {
    const ac = b.adjustedCurrent().?;
    if (ac.node.ns == .svg) {
        if (svg_tags.get(s.name)) |to| s.name = to;
        adjustSvgAttrs(s);
    } else {
        adjustMathAttrs(s);
    }
    adjustForeignAttrs(s);
    _ = try b.insertForeign(s.name, ac.node.ns, s.attrs);
    if (s.self_closing) b.pop();
}

fn endOther(b: *Builder, t: *Token, s: *const tz.Tag) Error!Act {
    var i = b.open.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.open.items[i];
        if (i == 0) return .done;
        if (std.ascii.eqlIgnoreCase(e.node.tag, s.name)) {
            b.popUntilNode(e.node);
            return .done;
        }
        if (b.open.items[i - 1].node.ns == .html) return b.html(t);
    }
    return .done;
}
