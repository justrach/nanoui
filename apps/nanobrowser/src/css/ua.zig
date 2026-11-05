//! The user agent stylesheet, after the HTML standard's rendering section.
//! Text sizes are the browsers' defaults; system colors follow the page's
//! `color-scheme`.

pub const sheet =
    \\html, address, blockquote, body, center, dialog, div, figure, figcaption, footer, form,
    \\header, hr, legend, listing, main, p, plaintext, pre, search, xmp, article, aside, h1, h2,
    \\h3, h4, h5, h6, hgroup, nav, section, dir, dd, dl, dt, menu, ol, ul, details, summary,
    \\fieldset, optgroup, option { display: block; }
    \\area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script,
    \\style, template, title, noscript { display: none; }
    \\[hidden], dialog:not([open]) { display: none; }
    \\[hidden=until-found i] { display: block; content-visibility: hidden; }
    \\[popover]:not(:popover-open) { display: none; }
    \\[popover] { position: fixed; inset: 0; width: fit-content; height: fit-content; margin: auto; border: solid; padding: 0.25em; overflow: auto; color: CanvasText; background-color: Canvas; }
    \\embed[hidden] { display: inline-block; height: 0; width: 0; }
    \\input[type=hidden i] { display: none !important; }
    \\slot { display: contents; }
    \\html { color: CanvasText; }
    \\body { margin: 8px; }
    \\
    \\address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr,
    \\legend, listing, main, p, plaintext, pre, search, xmp { unicode-bidi: isolate; }
    \\blockquote, figure { margin-block: 1em; margin-inline: 40px; }
    \\center { text-align: -webkit-center; }
    \\dd { margin-inline-start: 40px; }
    \\dl, p, listing, plaintext, pre, xmp { margin-block: 1em; }
    \\dir dl, dl dir, menu dl, dl menu, ol dl, dl ol, ul dl, dl ul { margin-block: 0; }
    \\address, cite, dfn, em, i, var { font-style: italic; }
    \\b, strong { font-weight: bolder; }
    \\code, kbd, listing, plaintext, pre, samp, tt, xmp { font-family: monospace; }
    \\listing, plaintext, pre, xmp { white-space: pre; }
    \\textarea { white-space: pre-wrap; }
    \\big { font-size: larger; }
    \\small { font-size: smaller; }
    \\sub { vertical-align: sub; font-size: smaller; }
    \\sup { vertical-align: super; font-size: smaller; }
    \\s, strike, del { text-decoration: line-through; }
    \\u, ins { text-decoration: underline; }
    \\abbr[title], acronym[title] { text-decoration: dotted underline; }
    \\mark { background-color: Mark; color: MarkText; }
    \\nobr { white-space: nowrap; }
    \\wbr { white-space: normal; }
    \\q::before { content: open-quote; }
    \\q::after { content: close-quote; }
    \\ruby { display: inline; }
    \\rt { font-size: 50%; }
    \\
    \\:link, :visited { color: LinkText; }
    \\a:-webkit-any-link { color: LinkText; text-decoration: underline; cursor: pointer; }
    \\a:-webkit-any-link:active { color: ActiveText; }
    \\area:-webkit-any-link { cursor: pointer; }
    \\:focus-visible { outline: auto 1px AccentColor; }
    \\a:focus-visible { outline-offset: 1px; }
    \\
    \\h1 { margin-block: 0.67em; font-size: 2em; font-weight: bold; }
    \\h2 { margin-block: 0.83em; font-size: 1.5em; font-weight: bold; }
    \\h3 { margin-block: 1em; font-size: 1.17em; font-weight: bold; }
    \\h4 { margin-block: 1.33em; font-size: 1em; font-weight: bold; }
    \\h5 { margin-block: 1.67em; font-size: 0.83em; font-weight: bold; }
    \\h6 { margin-block: 2.33em; font-size: 0.67em; font-weight: bold; }
    \\:is(article, aside, nav, section) h1 { margin-block: 0.83em; font-size: 1.5em; }
    \\:is(article, aside, nav, section) :is(article, aside, nav, section) h1 { margin-block: 1em; font-size: 1.17em; }
    \\hr { color: gray; border-style: inset; border-width: 1px; margin-block: 0.5em; margin-inline: auto; overflow: hidden; box-sizing: content-box; }
    \\
    \\dir, menu, ol, ul { padding-inline-start: 40px; margin-block: 1em; list-style-type: disc; }
    \\ol { list-style-type: decimal; }
    \\:is(dir, menu, ol, ul) :is(dir, menu, ol, ul) { margin-block: 0; }
    \\:is(dir, menu, ul) :is(dir, menu, ul) { list-style-type: circle; }
    \\:is(dir, menu, ol, ul) :is(dir, menu, ul) :is(dir, menu, ul) { list-style-type: square; }
    \\ol ol, ol ul ol { list-style-type: decimal; }
    \\li { display: list-item; text-align: match-parent; }
    \\summary { display: list-item; cursor: pointer; }
    \\summary { list-style: disclosure-closed inside; }
    \\details[open] > summary:first-of-type { list-style-type: disclosure-open; }
    \\
    \\table { display: table; box-sizing: border-box; border-spacing: 2px; border-collapse: separate; text-indent: 0; }
    \\caption { display: table-caption; text-align: center; }
    \\colgroup { display: table-column-group; }
    \\col { display: table-column; }
    \\thead { display: table-header-group; vertical-align: middle; }
    \\tbody { display: table-row-group; vertical-align: middle; }
    \\tfoot { display: table-footer-group; vertical-align: middle; }
    \\tr { display: table-row; vertical-align: inherit; }
    \\td, th { display: table-cell; padding: 1px; vertical-align: inherit; }
    \\th { font-weight: bold; text-align: -webkit-center; }
    \\
    \\input, select, button, textarea { display: inline-block; box-sizing: border-box; color: FieldText; font-size: 13.333px; font-family: Arial, sans-serif; font-weight: normal; line-height: normal; letter-spacing: normal; word-spacing: normal; text-transform: none; text-indent: 0; text-align: start; cursor: text; }
    \\input, textarea { background-color: Field; border: 2px inset ButtonBorder; padding: 1px 2px; }
    \\select { background-color: Field; border: 1px solid ButtonBorder; border-radius: 5px; padding: 0 2px; cursor: default; white-space: pre; }
    \\select[multiple], select[size] { height: auto; }
    \\option { padding: 0 2px; min-height: 1.2em; white-space: nowrap; font-weight: normal; }
    \\optgroup { font-weight: bold; }
    \\button, input[type=button i], input[type=submit i], input[type=reset i], input[type=color i] { background-color: ButtonFace; color: ButtonText; border: 2px outset ButtonBorder; border-radius: 3px; padding: 1px 6px; text-align: center; cursor: default; }
    \\input[type=file i] { background-color: transparent; border: 0; padding: 0; cursor: default; }
    \\input[type=checkbox i], input[type=radio i] { background-color: transparent; border: 0; padding: 0; margin: 3px 3px 3px 4px; width: 13px; height: 13px; cursor: default; }
    \\input[type=radio i] { border-radius: 50%; }
    \\input[type=range i] { background-color: transparent; border: 0; padding: 0; width: 129px; height: 16px; cursor: default; }
    \\input[type=image i] { background-color: transparent; border: 0; padding: 0; cursor: pointer; }
    \\input:disabled, select:disabled, button:disabled, textarea:disabled { color: GrayText; cursor: default; }
    \\fieldset { border: 2px groove ButtonBorder; margin-inline: 2px; padding-block: 0.35em 0.625em; padding-inline: 0.75em; min-width: min-content; }
    \\legend { padding-inline: 2px; }
    \\textarea { overflow: auto; cursor: text; }
    \\label { cursor: default; }
    \\meter, progress { display: inline-block; }
    \\
    \\img, video, canvas, iframe, embed, object, svg { display: inline-block; }
    \\img { display: inline; overflow: clip; }
    \\video, canvas, iframe, embed, object { overflow: clip; }
    \\iframe { border: 2px inset ButtonBorder; }
    \\svg:not(:root) { overflow: hidden; }
    \\marquee { display: inline-block; }
    \\[popover]:not(:popover-open) { display: none; }
    \\dialog { position: absolute; left: 0; right: 0; width: fit-content; height: fit-content; margin: auto; border: solid; padding: 1em; background-color: Canvas; color: CanvasText; }
    \\dialog:modal { position: fixed; overflow: auto; top: 0; bottom: 0; max-width: calc(100% - 6px - 2em); max-height: calc(100% - 6px - 2em); }
    \\frameset { display: block; }
    \\frame { display: block; }
    \\
;

/// In quirks mode a table does not inherit its text style, the historic
/// behaviour many old pages depend on.
pub const quirks =
    \\table { font-weight: initial; font-style: initial; font-size: initial; font-family: inherit; color: initial; white-space: initial; line-height: initial; text-align: initial; }
    \\form { margin-block-end: 1em; }
    \\
;
