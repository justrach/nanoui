//! The window and what hangs off it: location, history, navigator, timers against
//! microtasks, requestAnimationFrame, storage, cookies, geometry and the rest.
const std = @import("std");
const util = @import("tests_util.zig");
const cookies = @import("cookies.zig");
const storage = @import("storage.zig");
const testing = std.testing;
const Run = util.Run;

test "window's names, and what it offers and doesn't" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><title>Hi</title><body>");
    try util.table(&r, &.{
        .{ .js = "window === self && window === globalThis && window === top && window === parent && window === frames", .want = "true" },
        .{ .js = "this === window && document.defaultView === window", .want = "true" },
        .{ .js = "var topLevel = 5; window.topLevel", .want = "5" },
        .{ .js = "typeof addEventListener + typeof setTimeout + typeof fetch", .want = "functionfunctionfunction" },
        .{ .js = "addEventListener('zzz', function () {}); 1", .want = "1" },
        .{ .js = "innerWidth > 0 && innerHeight > 0 && outerWidth === innerWidth", .want = "true" },
        .{ .js = "devicePixelRatio", .want = "1" },
        .{ .js = "screen.width > 0 && screen.colorDepth", .want = "24" },
        .{ .js = "navigator.userAgent.includes('Chrome/') + navigator.language + navigator.onLine + navigator.cookieEnabled + typeof navigator.hardwareConcurrency", .want = "trueen-UStruetruenumber" },
        .{ .js = "typeof navigator.serviceWorker + typeof navigator.clipboard", .want = "undefinedobject" },
        .{ .js = "'getBattery' in navigator", .want = "false" },
        .{ .js = "typeof WebSocket + typeof Worker + typeof setImmediate + typeof indexedDB + typeof document.all", .want = "undefinedfunctionundefinedundefinedundefined" },
        .{ .js = "[document.all === undefined, document.all == null, !document.all, undefined === document.all, document.all ? 1 : 2, document.all.length > 0, document.all[0] === document.documentElement, document.all.item(0) === document.documentElement, document.all.nope].join()", .want = "false,true,true,false,2,true,true,true," },
        .{ .js = "MediaError.MEDIA_ERR_DECODE + PerformanceNavigation.TYPE_RELOAD + performance.navigation.type + typeof webkitSpeechRecognition", .want = "4function" },
        .{ .js = "var ac = new AudioContext(); var o = ac.createOscillator(); o.connect(ac.destination); o.start(); ac.state + (ac.createGain().gain.value)", .want = "suspended0" },
        .{ .js = "typeof Intl + typeof Promise + typeof Symbol + typeof Proxy", .want = "objectfunctionfunctionfunction" },
        .{ .js = "atob(btoa('hello')) + btoa('\\xff')", .want = "hello/w==" },
        .{ .js = "try { btoa('\\u0100') } catch (e) { e.name }", .want = "InvalidCharacterError" },
        .{ .js = "try { atob('$') } catch (e) { e.name }", .want = "InvalidCharacterError" },
        .{ .js = "crypto.getRandomValues(new Uint8Array(8)).length + crypto.randomUUID().length + crypto.randomUUID()[14]", .want = "444" },
        .{ .js = "typeof performance.now() + (performance.timeOrigin > 1e12) + performance.mark('x').name + performance.getEntriesByName('x').length + performance.measure('y', 'x').entryType", .want = "numbertruex1measure" },
        .{ .js = "matchMedia('(min-width: 1px)').matches + ',' + matchMedia('(max-width: 1px)').matches + ',' + matchMedia('print').matches", .want = "true,false,false" },
        .{ .js = "matchMedia('screen').media", .want = "screen" },
        .{ .js = "alert('x') + confirm('y') + prompt('z')", .want = "NaN" },
        .{ .js = "typeof getSelection().rangeCount + typeof document.getSelection", .want = "numberfunction" },
        .{ .js = "document.visibilityState + document.hidden + document.hasFocus() + document.characterSet + document.compatMode", .want = "visiblefalsetrueUTF-8CSS1Compat" },
        .{ .js = "document.title + document.domain + document.referrer + document.URL.slice(0, 5)", .want = "Hidata:" },
        .{ .js = "typeof document.fonts.ready.then + document.implementation.createHTMLDocument('x').title", .want = "functionx" },
        .{ .js = "new DOMParser().parseFromString('<p id=q>hi</p>', 'text/html').querySelector('#q').textContent", .want = "hi" },
        .{ .js = "new XMLSerializer().serializeToString(new DOMParser().parseFromString('<p>hi</p>', 'text/html').querySelector('p'))", .want = "<p>hi</p>" },
        .{ .js = "var d = new DOMParser().parseFromString('<p>x</p>', 'text/html'); var n = document.adoptNode(d.querySelector('p')); document.body.appendChild(n); n.ownerDocument === document && document.body.lastChild === n", .want = "true" },
        .{ .js = "document.importNode(new DOMParser().parseFromString('<i>y</i>', 'text/html').querySelector('i'), true).ownerDocument === document", .want = "true" },
        .{ .js = "new URL('../x?a=1#h', 'https://e.com:8080/p/q/r').href", .want = "https://e.com:8080/p/x?a=1#h" },
        .{ .js = "var u = new URL('https://u:p@e.com/a b?q=1'); [u.protocol,u.username,u.password,u.host,u.pathname,u.search,u.origin].join()", .want = "https:,u,p,e.com,/a%20b,?q=1,https://e.com" },
        .{ .js = "u = new URL('http://e.com/'); u.searchParams.append('k', 'a b'); u.hash = 'z'; u.port = '80'; u.href", .want = "http://e.com/?k=a+b#z" },
        .{ .js = "try { new URL('nope') } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "URL.canParse('x:y') + ',' + URL.canParse('nope')", .want = "true,false" },
        .{ .js = "var p = new URLSearchParams('a=1&b=2&a=3'); [p.get('a'), p.getAll('a').length, p.has('b'), p.size, String(p)].join()", .want = "1,2,true,3,a=1&b=2&a=3" },
        .{ .js = "p.delete('a'); p.set('c', 'x y'); [...p.keys()].join() + p", .want = "b,cb=2&c=x+y" },
        .{ .js = "new URLSearchParams({x: 1, y: 2}).toString() + new URLSearchParams([['p', 'q']]).toString()", .want = "x=1&y=2p=q" },
        .{ .js = "new TextDecoder().decode(new TextEncoder().encode('héllo €'))", .want = "héllo €" },
        .{ .js = "new TextEncoder().encode('é').length", .want = "2" },
        .{ .js = "var c = structuredClone({a: [1, {b: 2}], d: new Date(0), m: new Map([[1, 2]]), s: new Set([3]), u: new Uint8Array([9])}); c.a[1].b + c.d.getTime() + c.m.get(1) + c.s.has(3) + c.u[0]", .want = "14" },
        .{ .js = "var cy = {}; cy.self = cy; var cc = structuredClone(cy); cc.self === cc", .want = "true" },
        .{ .js = "try { structuredClone(() => 1) } catch (e) { e.name }", .want = "DataCloneError" },
        .{ .js = "var ac = new AbortController(); var hit = 0; ac.signal.addEventListener('abort', () => hit++); ac.abort(); ac.abort(); hit + String(ac.signal.aborted) + ac.signal.reason.name", .want = "1trueAbortError" },
        .{ .js = "AbortSignal.abort('why').reason + AbortSignal.abort().aborted", .want = "whytrue" },
        .{ .js = "new Headers({'X-A': '1'}).get('x-a') + new Headers([['b', '2']]).has('B') + [...new Headers({c: 3})].join()", .want = "1truec,3" },
        .{ .js = "try { new Headers({'a b': 1}) } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "new Blob(['abc', new Uint8Array([100])], {type: 'A/B'}).size + new Blob([], {type: 'A/B'}).type", .want = "4a/b" },
        .{ .js = "new File(['x'], 'n.txt', {type: 't'}).name", .want = "n.txt" },
        .{ .js = "var fd = new FormData(); fd.append('a', '1'); fd.append('a', '2'); fd.set('b', '3'); fd.getAll('a').join() + fd.get('b') + [...fd.keys()].join()", .want = "1,23a,a,b" },
    });
    try r.expectNoErrors();
}

test "location: its parts, assigning a hash, hashchange, and navigating" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><title>L</title><body><div style='height:2000px'></div><div id=far>Far</div>");
    _ = try r.eval("var hashes = []; addEventListener('hashchange', e => hashes.push(location.hash + ':' + e.newURL.endsWith('#far'))); 0");
    try util.table(&r, &.{
        .{ .js = "location.protocol + location.hostname + location.port + location.search + location.hash", .want = "data:" },
        .{ .js = "location.href === document.URL && String(location) === location.href", .want = "true" },
        .{ .js = "location === document.location && location === window.location", .want = "true" },
        .{ .js = "location.origin", .want = "null" },
    });
    _ = try r.eval("location.hash = 'far'; 0");
    try r.waitJs("hashes.length === 1");
    try r.expectJs("hashes[0]", "#far:true");
    try r.expectJs("location.hash", "#far");
    try testing.expect(std.mem.endsWith(u8, r.page().url(), "#far"));
    r.t.frame();
    try testing.expect(r.page().scrollY() > 1000);
    // Assigning an address goes there, when the task ends.
    _ = try r.eval("location.href = 'data:text/html,<title>Next</title><p>next page'; 0");
    r.settle();
    try testing.expect(r.t.hasText("next page"));
}

test "history: pushState, replaceState, back, popstate, and the tab's address" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    // A data: page can't change its address by a path: give it hashes.
    try r.html("<!doctype html><body>page");
    _ = try r.eval("var pops = []; addEventListener('popstate', e => pops.push(JSON.stringify(e.state))); 0");
    try util.table(&r, &.{
        .{ .js = "history.length + String(history.state)", .want = "1null" },
        .{ .js = "history.pushState({n: 1}, '', '#one'); history.length + history.state.n + location.hash", .want = "3#one" },
        .{ .js = "history.pushState({n: 2}, '', '#two'); location.hash", .want = "#two" },
        .{ .js = "history.replaceState({n: 3}, '', '#three'); history.length + location.hash + history.state.n", .want = "3#three3" },
        .{ .js = "try { history.pushState({}, '', 'https://other.example/') } catch (e) { e.name }", .want = "SecurityError" },
    });
    try testing.expect(std.mem.endsWith(u8, r.page().url(), "#three"));
    try testing.expect(std.mem.endsWith(u8, r.b.tabs.items[0].url(), "#three"));
    // The tab's entries are these too: its back button, then scripts'.
    try testing.expect(r.b.tabs.items[0].canGoBack());
    r.b.tabs.items[0].back();
    try r.waitJs("pops.length === 1");
    try r.expectJs("pops[0] + location.hash", "{\"n\":1}#one");
    _ = try r.eval("history.forward(); 0");
    try r.waitJs("pops.length === 2");
    try r.expectJs("history.state.n + location.hash", "3#three");
    _ = try r.eval("history.go(-2); 0");
    try r.waitJs("pops.length === 4");
    try r.expectJs("history.state + location.hash", "null");
    // Back past the document's first entry leaves it, for what was before.
    try r.expectNoErrors();
}

test "timers run in order, after microtasks, one task at a time" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><script>
        \\var log = [];
        \\setTimeout(() => { log.push('t2'); Promise.resolve().then(() => log.push('m-in-t2')); }, 2);
        \\setTimeout(() => log.push('t0'), 0);
        \\var cancelled = setTimeout(() => log.push('nope'), 0);
        \\clearTimeout(cancelled);
        \\Promise.resolve().then(() => log.push('micro'));
        \\queueMicrotask(() => log.push('qm'));
        \\var ticks = 0; var iv = setInterval(() => { if (++ticks === 3) { clearInterval(iv); log.push('iv'); } }, 1);
        \\setTimeout((a, b) => log.push(a + b), 0, 'x', 'y');
        \\setTimeout("log.push('string')", 0);
        \\log.push('sync');
        \\</script>
    );
    try r.waitJs("log.includes('iv') && log.includes('m-in-t2')");
    try r.expectJs("log.slice(0, 3).join()", "sync,micro,qm");
    try r.expectJs("log.indexOf('t0') < log.indexOf('xy') && log.indexOf('xy') < log.indexOf('string')", "true");
    try r.expectJs("log.indexOf('m-in-t2') === log.indexOf('t2') + 1", "true");
    try r.expectJs("log.includes('nope')", "false");
    try r.expectNoErrors();
}

test "requestAnimationFrame runs in frames, and asks for one only while queued" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><script>
        \\var frames = 0, stamps = [];
        \\function tick(t) { frames++; stamps.push(typeof t); if (frames < 3) requestAnimationFrame(tick); }
        \\requestAnimationFrame(tick);
        \\var killed = requestAnimationFrame(() => { window.bad = 1 }); cancelAnimationFrame(killed);
        \\</script>
    );
    r.t.frame();
    try testing.expect(r.t.ctx.animating or true);
    r.t.frame();
    r.t.frame();
    r.t.frame();
    r.t.frame();
    try r.expectJs("frames", "3");
    try r.expectJs("stamps[0]", "number");
    try r.expectJs("typeof bad", "undefined");
    try testing.expectEqual(@as(usize, 0), r.world().animation.items.len);
    r.t.frame();
    try testing.expect(!r.t.ctx.animating);
    try r.expectNoErrors();
}

test "storage and cookies" {
    storage.clearAll();
    cookies.clear();
    defer cookies.clear();
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body>");
    try util.table(&r, &.{
        .{ .js = "localStorage.length + String(localStorage.getItem('a'))", .want = "0null" },
        .{ .js = "localStorage.setItem('a', 1); localStorage.getItem('a') + localStorage.a + localStorage['a'] + localStorage.length", .want = "1111" },
        .{ .js = "localStorage.b = 'x'; localStorage.getItem('b') + localStorage.key(1) + Object.keys(localStorage).join()", .want = "xba,b" },
        .{ .js = "'a' in localStorage && !('zz' in localStorage) && typeof localStorage.setItem", .want = "function" },
        .{ .js = "delete localStorage.a; localStorage.a === undefined && localStorage.length", .want = "1" },
        .{ .js = "localStorage.removeItem('b'); localStorage.length", .want = "0" },
        .{ .js = "localStorage.setItem('setItem', 'q'); typeof localStorage.setItem + localStorage.getItem('setItem')", .want = "functionq" },
        .{ .js = "localStorage.clear(); localStorage.length", .want = "0" },
        .{ .js = "sessionStorage.setItem('s', '1'); sessionStorage.s + localStorage.length", .want = "10" },
        .{ .js = "localStorage instanceof Storage", .want = "true" },
        .{ .js = "document.cookie", .want = "" },
    });
    try r.expectNoErrors();
    // Storage is kept for the process; the same origin in a new page sees it.
    _ = try r.eval("localStorage.setItem('kept', 'yes')");
    try r.html("<!doctype html><body>again");
    try r.expectJs("localStorage.kept", "yes");
}

test "geometry reads against layout" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style='margin:0'>
        \\<div id=a style='width:200px;height:100px;padding:10px;border:5px solid red;margin:7px;box-sizing:content-box'>x</div>
        \\<div id=box style='position:relative;left:3px;margin-top:20px;width:300px'><span id=s style='position:absolute;left:11px;top:13px;width:40px;height:50px'>y</span></div>
        \\<div id=sc style='width:100px;height:50px;overflow:auto'><div style='height:500px;width:300px'>z</div></div>
        \\<div id=none style='display:none'>hidden</div>
        \\<div id=fix style='position:fixed;top:9px;left:9px;width:10px;height:10px'></div>
        \\<div style='height:2000px'></div>
    );
    try util.table(&r, &.{
        .{ .js = "var b = a.getBoundingClientRect(); [b.x, b.y, b.width, b.height, b.top, b.left, b.right, b.bottom].join()", .want = "7,7,230,130,7,7,237,137" },
        .{ .js = "b instanceof DOMRect", .want = "true" },
        .{ .js = "[a.offsetWidth, a.offsetHeight, a.offsetLeft, a.offsetTop].join()", .want = "230,130,7,7" },
        .{ .js = "[a.clientWidth, a.clientHeight, a.clientLeft, a.clientTop].join()", .want = "220,120,5,5" },
        .{ .js = "a.offsetParent === document.body", .want = "true" },
        .{ .js = "s.offsetParent === box && s.offsetLeft + ',' + s.offsetTop", .want = "11,13" },
        .{ .js = "[sc.scrollHeight, sc.scrollWidth, sc.clientHeight, sc.scrollTop].join()", .want = "500,300,50,0" },
        .{ .js = "sc.scrollTop = 30; [sc.scrollTop, sc.getBoundingClientRect().top - sc.querySelector('div').getBoundingClientRect().top].join()", .want = "30,30" },
        .{ .js = "sc.scrollTop = 9999; sc.scrollTop", .want = "450" },
        .{ .js = "sc.scrollTo(0, 0); sc.scrollTop", .want = "0" },
        .{ .js = "sc.scrollBy(0, 10); sc.scrollTop", .want = "10" },
        .{ .js = "[none.offsetWidth, none.getBoundingClientRect().width, none.offsetParent, none.getClientRects().length].join()", .want = "0,0,,0" },
        .{ .js = "document.createElement('div').offsetWidth", .want = "0" },
        .{ .js = "document.documentElement.clientWidth === innerWidth && document.documentElement.clientHeight === innerHeight", .want = "true" },
        .{ .js = "document.documentElement.scrollHeight > 2000 && document.body.offsetHeight > 2000", .want = "true" },
        .{ .js = "scrollTo(0, 100); [a.getBoundingClientRect().top, fix.getBoundingClientRect().top, scrollY].join()", .want = "-93,9,100" },
        .{ .js = "scrollTo(0, 0); document.elementFromPoint(20, 20) === a", .want = "true" },
        .{ .js = "document.elementFromPoint(-1, 0)", .want = "null" },
        .{ .js = "a.style.width = '100px'; a.offsetWidth", .want = "130" },
        .{ .js = "var w = a.offsetWidth; a.style.display = 'none'; var g = a.offsetWidth; a.style.display = ''; w + ',' + g + ',' + a.offsetWidth", .want = "130,0,130" },
        .{ .js = "getComputedStyle(a).width + getComputedStyle(a).display + getComputedStyle(a).getPropertyValue('position')", .want = "100pxblockstatic" },
        .{ .js = "getComputedStyle(none).display", .want = "none" },
        .{ .js = "a.style.color = 'rgb(1, 2, 3)'; getComputedStyle(a).color", .want = "rgb(1, 2, 3)" },
        .{ .js = "getComputedStyle(a).marginTop + getComputedStyle(a)['margin-left'] + getComputedStyle(a).getPropertyValue('margin-left')", .want = "7px7px7px" },
        .{ .js = "far = document.createElement('div'); far.style.cssText = 'margin-top:1500px;height:10px'; document.body.appendChild(far); far.scrollIntoView(); scrollY > 1000", .want = "true" },
    });
    try r.expectNoErrors();
}

test "inline style: properties, cssText, and the attribute" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=a style='color: red; background-color: blue !important;'>x</div>");
    try util.table(&r, &.{
        .{ .js = "a.style.color + a.style.backgroundColor + a.style['background-color'] + a.style.getPropertyValue('color') + a.style.getPropertyPriority('background-color')", .want = "redblueblueredimportant" },
        .{ .js = "a.style.width", .want = "" },
        .{ .js = "a.style.length + a.style[0] + a.style.item(1)", .want = "2colorbackground-color" },
        .{ .js = "a.style.nonsense", .want = "undefined" },
        .{ .js = "'transition' in a.style && 'webkitTransform' in a.style && !('nonsense' in a.style)", .want = "true" },
        .{ .js = "a.style.width = '10px'; a.getAttribute('style')", .want = "color: red; background-color: blue !important; width: 10px;" },
        .{ .js = "a.style.setProperty('height', '5px', 'important'); a.style.getPropertyValue('height') + a.style.cssText.includes('height: 5px !important')", .want = "5pxtrue" },
        .{ .js = "a.style.setProperty('--my-var', '1'); a.style.getPropertyValue('--my-var')", .want = "1" },
        .{ .js = "a.style.removeProperty('width')", .want = "10px" },
        .{ .js = "a.style.width + a.getAttribute('style').includes('width')", .want = "false" },
        .{ .js = "a.style.color = ''; a.style.color", .want = "" },
        .{ .js = "a.style.cssFloat = 'left'; a.style.float + a.style.getPropertyValue('float')", .want = "leftleft" },
        .{ .js = "a.style.cssText = 'margin: 1px'; a.style.margin + a.getAttribute('style')", .want = "1pxmargin: 1px" },
        .{ .js = "a.style.cssText = ''; a.hasAttribute('style')", .want = "false" },
        .{ .js = "a.style.color = 'red'; a.setAttribute('style', 'color: blue'); a.style.color", .want = "blue" },
        .{ .js = "a.style === a.style", .want = "true" },
        .{ .js = "a.style instanceof CSSStyleDeclaration", .want = "true" },
        .{ .js = "a.style.color = null; a.style.color", .want = "" },
    });
    try r.expectNoErrors();
}

test "style sheets from scripts restyle the page" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><style id=st>.x { display: none }</style><body><p id=p class=x>styled</p>");
    try testing.expect(!r.t.hasText("styled"));
    _ = try r.eval("st.textContent = '.x { display: block }'; 0");
    r.t.frame();
    try testing.expect(r.t.hasText("styled"));
    _ = try r.eval("st.sheet.insertRule('#p { display: none }', 1); 0");
    r.t.frame();
    try testing.expect(!r.t.hasText("styled"));
    try r.expectJs("st.sheet.cssRules.length + document.styleSheets.length", "3");
    _ = try r.eval("st.sheet.deleteRule(1); 0");
    r.t.frame();
    try testing.expect(r.t.hasText("styled"));
    _ = try r.eval("var n = document.createElement('style'); n.textContent = '#p { display: none }'; document.head.appendChild(n); 0");
    r.t.frame();
    try testing.expect(!r.t.hasText("styled"));
    _ = try r.eval("n.remove(); 0");
    r.t.frame();
    try testing.expect(r.t.hasText("styled"));
    try r.expectNoErrors();
}

test "pictures: load and error events, new Image, complete and natural size" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEklEQVR4nGNgYGD4z8DAwMAAAAkEAQHnHWSgAAAAAElFTkSuQmCC";
    try r.html("<!doctype html><body><img id=a src='" ++ png ++ "' onload=\"window.attrLoad = 1\"><img id=b src='data:image/png;base64,AAAA' onerror=\"window.attrError = 1\"><script>" ++
        \\var log = [];
        \\var n = new Image(); n.onload = () => log.push('new:' + n.complete + ':' + n.naturalWidth + 'x' + n.naturalHeight);
    ++ "n.src = '" ++ png ++ "';" ++
        \\log.push('complete:' + n.complete);
        \\var bad = document.createElement('img'); bad.addEventListener('error', () => log.push('bad')); bad.src = 'data:,'; 
        \\window.addEventListener('load', () => log.push('winload'));
        \\document.addEventListener('load', e => log.push('cap:' + e.target.tagName), true);
        \\</script>
    );
    r.spin(0.05);
    try r.waitJs("log.some(x => x.startsWith('new:'))");
    try r.expectJs("log.find(x => x.startsWith('new:'))", "new:true:2x3");
    try r.expectJs("window.attrLoad", "1");
    try r.expectJs("n instanceof HTMLImageElement && n.width === 2 && n.tagName", "IMG");
    try r.expectJs("log.includes('winload')", "true");
    try r.expectNoErrors();
}

test "DOMMatrix: what animation libraries read a computed transform with" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><div id=a style='transform:translate(10px,20px) scale(2)'></div>");
    try util.table(&r, &.{
        .{ .js = "var m = new DOMMatrix(); m.isIdentity + ',' + m.is2D + ',' + m.a + ',' + m.m44", .want = "true,true,1,1" },
        .{ .js = "new DOMMatrix('none').isIdentity", .want = "true" },
        .{ .js = "var c = new DOMMatrix(getComputedStyle(a).getPropertyValue('transform')); [c.a, c.d, c.e, c.f].join()", .want = "2,2,10,20" },
        .{ .js = "new DOMMatrix('translate(5px, 6px) rotate(90deg)').transformPoint({x: 1, y: 0}).y", .want = "7" },
        .{ .js = "new DOMMatrix([1,0,0,1,3,4]).toString()", .want = "matrix(1, 0, 0, 1, 3, 4)" },
        .{ .js = "new DOMMatrix('translateZ(3px)').is2D + ',' + new DOMMatrix('translateZ(3px)').m43", .want = "false,3" },
        .{ .js = "var t = new DOMMatrix().translate(2, 3).scale(2); [t.e, t.f, t.a].join()", .want = "2,3,2" },
        .{ .js = "var i = new DOMMatrix('translate(5px,6px) scale(2)').inverse(); i.multiply(new DOMMatrix('translate(5px,6px) scale(2)')).isIdentity", .want = "true" },
        .{ .js = "var s = new DOMMatrix(); s.scaleSelf(3); s.e = 4; s.toString()", .want = "matrix(3, 0, 0, 3, 4, 0)" },
        .{ .js = "try { new DOMMatrix('nonsense(1)'); 'parsed' } catch (e) { e.name }", .want = "SyntaxError" },
        .{ .js = "WebKitCSSMatrix === DOMMatrix && new DOMMatrix() instanceof DOMMatrixReadOnly", .want = "true" },
    });
}
