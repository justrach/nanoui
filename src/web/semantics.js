// DOM projection of the current Zig frame. The canvas owns layout and paint.
const button = new Set(["button", "tab", "checkbox", "switch_toggle", "radio_button", "row", "option", "menu_button", "link"]);
const roles = { checkbox: "checkbox", switch_toggle: "switch", radio_button: "radio", tab: "tab", option: "option", link: "link", menu_button: "button" };
const containers = new Set(["list", "listbox"]);
const tagFor = (item, combobox) => item.role === "text_field" ? (item.password || combobox ? "input" : "textarea") :
  containers.has(item.role) ? "div" : button.has(item.role) ? "button" : "span";
let nextProjection = 0;
const isEditor = node => node?.tagName === "TEXTAREA" || node?.tagName === "INPUT";

export function createSemantics(canvas, send) {
  const prefix = `nanoui-${++nextProjection}-`;
  const domId = id => `${prefix}${id}`;
  const root = document.createElement("div");
  root.dataset.nanouiSemantics = "";
  const live = document.createElement("span");
  live.setAttribute("role", "status");
  live.style.cssText = "position:fixed;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)";
  root.append(live);
  canvas.after(root);
  const nodes = new Map();
  let lastJson, focused, editor;
  let reconciling = false;
  const encoder = new TextEncoder();

  // `box` is the control's area; `anchor` is where its node sits, which for
  // the focused editor is the caret, so IME candidates appear beside it.
  const place = (node, rect) => {
    node.anchor = rect;
    const b = canvas.getBoundingClientRect();
    Object.assign(node.style, {
      left: `${b.left + rect.x}px`, top: `${b.top + rect.y}px`,
      width: `${Math.max(1, rect.w)}px`, height: `${Math.max(1, rect.h)}px`,
    });
  };
  const sendText = (id, value) => {
    // Encode at delivery to keep the reusable WASM buffer scoped to one frame.
    if (!value || value.length > 65536) return;
    const bytes = encoder.encode(value);
    if (bytes.length <= 65536) send(["text", id, bytes, false]);
  };
  function create(item, id, tag) {
    const password = item.password;
    const node = document.createElement(tag);
    // 16px keeps iOS from zooming the page when the editor takes focus.
    node.style.cssText = "position:fixed;opacity:0;pointer-events:none;margin:0;box-sizing:border-box;font-size:16px";
    node.id = domId(id);
    node.box = item.rect;
    if (password) node.type = "password";
    if (tag === "button") {
      node.type = "button";
      node.addEventListener("click", () => send(["access", id, true]));
    }
    if (tag !== "span") node.addEventListener("focus", () => {
      if (!reconciling) send(["access", id, false]);
    });
    if (tag === "textarea" || tag === "input") {
      let composing = false;
      node.autocomplete = password ? "current-password" : "off";
      node.spellcheck = false;
      // Corrections would rewrite text Zig already holds.
      node.setAttribute("autocapitalize", "off");
      node.setAttribute("autocorrect", "off");
      node.addEventListener("compositionstart", () => {
        composing = true;
        if (focused?.id !== id || focused.password) return;
        node.style.opacity = "1";
        node.style.minWidth = "12ch";
      });
      node.addEventListener("compositionend", e => {
        composing = false;
        node.style.opacity = "0";
        node.style.minWidth = "";
        if (focused?.id === id) sendText(id, e.data);
        node.value = "";
      });
      node.addEventListener("blur", () => {
        composing = false;
        node.style.opacity = "0";
        node.style.minWidth = "";
        node.value = "";
      });
      node.addEventListener("input", e => {
        if (composing || e.isComposing) return;
        if (focused?.id === id && e.inputType !== "insertFromComposition")
          sendText(id, e.data ?? node.value);
        node.value = "";
      });
      node.addEventListener("paste", e => {
        if (focused?.id !== id || !e.clipboardData) return;
        e.preventDefault();
        sendText(id, e.clipboardData.getData("text/plain"));
      });
      for (const type of ["copy", "cut"]) node.addEventListener(type, e => {
        if (password) {
          e.preventDefault();
          return;
        }
        if (focused?.id !== id || !focused.selection || !e.clipboardData) return;
        e.clipboardData.setData("text/plain", focused.selection);
        e.preventDefault();
        if (type === "cut" && focused.selection.length <= 65536) {
          const bytes = encoder.encode(focused.selection);
          if (bytes.length <= 65536) send(["text", id, bytes, true]);
        }
      });
    }
    return node;
  }

  function publish(json) {
    if (json === lastJson) return;
    lastJson = json;
    const snapshot = JSON.parse(json);
    const active = document.activeElement;
    const owned = active === canvas || root.contains(active);
    const ids = new Set();
    reconciling = true;
    try {
      // Each parent's last placed child: the root's starts after the live region.
      const previous = new Map([[root, live]]);
      const lists = new Map();
      const itemsById = new Map(snapshot.items.map(item => [item.id, item]));
      const hasId = id => id && id !== "0";
      const isCombobox = item => item.role === "text_field" && !item.password && hasId(item.controls) &&
        (!itemsById.has(item.controls) || itemsById.get(item.controls).role === "listbox");
      const popups = new Set(snapshot.items.filter(isCombobox).map(item => item.controls));
      for (const item of snapshot.items) {
        const id = BigInt(item.id);
        ids.add(id);
        let node = nodes.get(id);
        const combobox = isCombobox(item);
        const tag = tagFor(item, combobox);
        if (node && (node.localName !== tag || (tag === "input" && (node.type === "password") !== !!item.password))) {
          node.remove();
          nodes.delete(id);
          node = undefined;
        }
        if (!node) {
          node = create(item, id, tag);
          nodes.set(id, node);
          root.append(node);
        }
        // A list's or listbox's elements live inside its node.
        const list = item.container && item.container !== "0" ? nodes.get(BigInt(item.container)) : null;
        const parent = list?.tagName === "DIV" ? list : root;
        if (list && parent === list) {
          const kinds = lists.get(list) ?? new Set();
          kinds.add(item.role);
          lists.set(list, kinds);
        }
        const last = previous.get(parent);
        const want = last ? last.nextSibling : parent.firstChild;
        // Leave the active node in place within its parent; moving other
        // siblings restores their order without blurring it. A change of
        // parent must still establish the new ownership before using siblings.
        if (node !== want && (node !== active || node.parentNode !== parent))
          parent.insertBefore(node, want);
        previous.set(parent, node);
        node.box = item.rect;
        place(node, item.rect);
        if (node.tagName === "SPAN") {
          if (node.textContent !== item.label) node.textContent = item.label;
          if (item.header) {
            node.setAttribute("role", "heading");
            node.setAttribute("aria-level", String(item.level || 2));
          } else {
            node.removeAttribute("role");
            node.removeAttribute("aria-level");
          }
        } else {
          if (node.getAttribute("aria-label") !== item.label) node.setAttribute("aria-label", item.label);
          // aria-disabled keeps disabled controls in screen-reader navigation;
          // Zig ignores actions on them.
          if (item.enabled) node.removeAttribute("aria-disabled");
          else node.setAttribute("aria-disabled", "true");
          // A list of tabs becomes a tab list below. Other lists are labelled groups.
          const role = combobox ? "combobox" : item.role === "list" ? "group" : item.role === "listbox" ? "listbox" : roles[item.role];
          if (role) node.setAttribute("role", role);
          else node.removeAttribute("role");
          const checked = ["checkbox", "switch_toggle", "radio_button"].includes(item.role);
          const selectable = item.role === "tab" || item.role === "option";
          if (checked) node.setAttribute("aria-checked", String(item.selected));
          else node.removeAttribute("aria-checked");
          if (selectable) node.setAttribute("aria-selected", String(item.selected));
          else node.removeAttribute("aria-selected");
          if (!checked && !selectable && item.selected) node.setAttribute("aria-current", "true");
          else node.removeAttribute("aria-current");
          for (const [name, value] of [["aria-posinset", item.position], ["aria-setsize", item.set_size]]) {
            if (item.role === "option" && value) node.setAttribute(name, String(value));
            else node.removeAttribute(name);
          }
          const controls = itemsById.get(item.controls);
          const descendant = itemsById.get(item.active_descendant);
          // Focus stays in the query while its listbox options are active descendants.
          if (combobox) {
            node.setAttribute("aria-expanded", String(!!controls));
            node.setAttribute("aria-autocomplete", "list");
          } else {
            node.removeAttribute("aria-expanded");
            node.removeAttribute("aria-autocomplete");
          }
          if (controls) node.setAttribute("aria-controls", domId(BigInt(controls.id)));
          else node.removeAttribute("aria-controls");
          if (controls && descendant?.container === controls.id)
            node.setAttribute("aria-activedescendant", domId(BigInt(descendant.id)));
          else node.removeAttribute("aria-activedescendant");
          if (item.role === "option" && popups.has(item.container)) node.tabIndex = -1;
          else node.removeAttribute("tabindex");
        }
      }
      for (const [list, kinds] of lists) if (kinds.has("tab") && list.getAttribute("role") === "group") list.setAttribute("role", "tablist");
      for (const [id, node] of nodes) if (!ids.has(id)) {
        node.remove();
        nodes.delete(id);
      }
      focused = snapshot.focus ? { ...snapshot.focus, id: BigInt(snapshot.focus.id) } : null;
      const nextEditor = focused ? nodes.get(focused.id) : null;
      if (isEditor(nextEditor)) {
        place(nextEditor, focused.rect);
        if (owned && document.activeElement !== nextEditor) nextEditor.focus({ preventScroll: true });
      } else if (owned && (active === editor || document.activeElement !== active)) {
        const restore = nodes.get(BigInt(snapshot.focused_id)) ?? canvas;
        restore.focus({ preventScroll: true });
      }
      editor = nextEditor;
      if (snapshot.announcement) live.textContent = snapshot.announcement;
    } finally {
      reconciling = false;
    }
  }

  // The canvas moves with page scroll, resizes and the on-screen keyboard.
  const relayout = () => { for (const node of nodes.values()) if (node.anchor) place(node, node.anchor); };
  const view = globalThis.visualViewport;
  globalThis.addEventListener("scroll", relayout, { capture: true, passive: true });
  globalThis.addEventListener("resize", relayout);
  view?.addEventListener("resize", relayout);
  view?.addEventListener("scroll", relayout);

  // The enabled editor under a canvas point, so a tap can focus it while the
  // browser still treats the event as a user gesture (iOS shows its
  // keyboard only then).
  function editorAt(x, y) {
    for (const node of nodes.values()) {
      const r = node.box;
      if (isEditor(node) && node.getAttribute("aria-disabled") !== "true" && r &&
          x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return node;
    }
    return null;
  }

  return { root, publish, editorAt, setCanvas(next) {
    canvas = next;
    lastJson = undefined;
  }, destroy() {
    globalThis.removeEventListener("scroll", relayout, { capture: true });
    globalThis.removeEventListener("resize", relayout);
    view?.removeEventListener("resize", relayout);
    view?.removeEventListener("scroll", relayout);
    root.remove();
    nodes.clear();
    lastJson = focused = editor = undefined;
  } };
}
