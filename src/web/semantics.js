// DOM projection of the current Zig frame. The canvas owns layout and paint.
const button = new Set(["button", "tab", "checkbox", "switch_toggle", "radio_button", "row", "menu_button", "link"]);
const roles = { switch_toggle: "switch", radio_button: "radio", menu_button: "button" };

export function createSemantics(canvas, send) {
  const root = document.createElement("div");
  root.dataset.nanouiSemantics = "";
  const live = document.createElement("span");
  live.setAttribute("role", "status");
  live.style.cssText = "position:fixed;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)";
  root.append(live);
  canvas.after(root);
  const nodes = new Map();
  let lastJson, focused, editor, composing = false;
  let reconciling = false;
  const encoder = new TextEncoder();

  const place = (node, rect) => {
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
  function create(item, id) {
    const tag = item.role === "text_field" ? "textarea" : button.has(item.role) ? "button" : "span";
    const node = document.createElement(tag);
    node.style.cssText = "position:fixed;opacity:0;pointer-events:none;margin:0;box-sizing:border-box";
    if (tag === "button") {
      node.type = "button";
      node.addEventListener("click", () => send(["access", id, true]));
    }
    if (tag !== "span") node.addEventListener("focus", () => {
      if (!reconciling) send(["access", id, false]);
    });
    if (tag === "textarea") {
      node.autocomplete = "off";
      node.spellcheck = false;
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
      let previous = live;
      for (const item of snapshot.items) {
        const id = BigInt(item.id);
        ids.add(id);
        let node = nodes.get(id);
        if (!node) {
          node = create(item, id);
          nodes.set(id, node);
          root.append(node);
        }
        if (node !== active && previous.nextSibling !== node)
          root.insertBefore(node, previous.nextSibling);
        previous = node;
        place(node, item.rect);
        if (node.tagName === "SPAN") {
          if (node.textContent !== item.label) node.textContent = item.label;
          if (item.header) {
            node.setAttribute("role", "heading");
            node.setAttribute("aria-level", "2");
          }
        } else {
          if (node.getAttribute("aria-label") !== item.label) node.setAttribute("aria-label", item.label);
          node.disabled = !item.enabled;
          if (item.selected) node.setAttribute("aria-current", "true");
          else node.removeAttribute("aria-current");
          if (item.role in roles) node.setAttribute("role", roles[item.role]);
          if (["checkbox", "switch_toggle", "radio_button"].includes(item.role))
            node.setAttribute("aria-checked", String(item.selected));
        }
      }
      for (const [id, node] of nodes) if (!ids.has(id)) {
        node.remove();
        nodes.delete(id);
      }
      focused = snapshot.focus ? { ...snapshot.focus, id: BigInt(snapshot.focus.id) } : null;
      const nextEditor = focused ? nodes.get(focused.id) : null;
      if (nextEditor?.tagName === "TEXTAREA") {
        place(nextEditor, focused.rect);
        if (owned && active !== nextEditor) nextEditor.focus({ preventScroll: true });
      } else if (owned && (active === editor || !active.isConnected)) {
        const restore = nodes.get(BigInt(snapshot.focused_id)) ?? canvas;
        restore.focus({ preventScroll: true });
      }
      editor = nextEditor;
      if (snapshot.announcement) live.textContent = snapshot.announcement;
    } finally {
      reconciling = false;
    }
  }

  return { root, publish, setCanvas(next) {
    canvas = next;
    lastJson = undefined;
  }, destroy() {
    root.remove();
    nodes.clear();
    lastJson = focused = editor = undefined;
  } };
}
