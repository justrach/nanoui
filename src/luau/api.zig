//! Direct declarations from Luau 0.746's lua.h, lualib.h and luacode.h.
//! Compiled with C linkage and LUA_USE_LONGJMP; no C/C++ shim.
pub const State = opaque {};
pub const globals: c_int = -10002;
pub const table: c_int = 7;
pub const function: c_int = 8;
pub const string: c_int = 6;
pub const number: c_int = 3;
pub const boolean: c_int = 1;
pub const Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
// Only the documented prefix is accessed; the remainder belongs to Luau.
pub const Callbacks = extern struct {
    userdata: ?*anyopaque,
    interrupt: ?*const fn (*State, c_int) callconv(.c) void,
};
pub extern fn lua_newstate(Alloc, ?*anyopaque) ?*State;
pub extern fn lua_close(*State) void;
pub extern fn lua_callbacks(*State) *Callbacks;
pub extern fn lua_gettop(*State) c_int;
pub extern fn lua_settop(*State, c_int) void;
pub extern fn lua_type(*State, c_int) c_int;
pub extern fn lua_pushnil(*State) void;
pub extern fn lua_pushnumber(*State, f64) void;
pub extern fn lua_pushboolean(*State, c_int) void;
pub extern fn lua_pushstring(*State, [*:0]const u8) void;
pub extern fn lua_pushvalue(*State, c_int) void;
pub extern fn lua_setfield(*State, c_int, [*:0]const u8) void;
pub extern fn lua_rawgetfield(*State, c_int, [*:0]const u8) c_int;
pub extern fn lua_rawgeti(*State, c_int, c_int) c_int;
pub extern fn lua_next(*State, c_int) c_int;
pub extern fn lua_objlen(*State, c_int) c_int;
pub extern fn lua_tolstring(*State, c_int, *usize) ?[*]const u8;
pub extern fn lua_tonumberx(*State, c_int, ?*c_int) f64;
pub extern fn lua_toboolean(*State, c_int) c_int;
pub extern fn lua_pcall(*State, c_int, c_int, c_int) c_int;
pub extern fn lua_error(*State) noreturn;
pub extern fn luaL_openlibs(*State) void;
pub extern fn luaL_sandbox(*State) void;
pub extern fn luau_load(*State, [*:0]const u8, [*]const u8, usize, c_int) c_int;
pub extern fn luau_compile([*]const u8, usize, ?*anyopaque, *usize) ?[*]u8;
pub extern "c" fn realloc(?*anyopaque, usize) ?*anyopaque;
pub extern "c" fn free(?*anyopaque) void;
pub fn pop(l: *State) void {
    lua_settop(l, -2);
}
pub fn text(l: *State, i: c_int) ?[]const u8 {
    if (lua_type(l, i) != string) return null;
    var len: usize = 0;
    const ptr = lua_tolstring(l, i, &len) orelse return null;
    return ptr[0..len];
}
