// The local page's own script. `nanoui.js` (generated) exports the bridge and
// a typed client per service and event, so an ES module imports what it uses.
// Switching pages is the bar nanoui injects into every document, so this
// page has no buttons of its own for that.
import { Todos, onTick } from "/nanoui.js";

const todos = await Todos.list();
document.getElementById("todos").innerHTML = todos
  .map((t) => `<li>${t.title}${t.done ? " — <b>done</b>" : ""}</li>`)
  .join("");

onTick(({ uptime }) => {
  document.getElementById("uptime").textContent = `${uptime}s`;
  document.getElementById("tick").textContent = `tick #${uptime} from Zig`;
});
