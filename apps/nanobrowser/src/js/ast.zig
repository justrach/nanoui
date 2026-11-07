//! The syntax tree, allocated in a per-compile arena. Patterns reuse the expression
//! nodes (array, object, assign with `=`, spread), as cover grammars parse them first
//! and a separate conversion would only copy. Scope information is attached by scope.zig.

const std = @import("std");
const JSString = @import("string.zig").JSString;
const T = @import("lexer.zig").T;

pub const VarKind = enum(u8) {
    @"var",
    let,
    @"const",
    param,
    function,
    class,
    catch_param,
    import,
    /// A named function expression's own name: assignment is ignored (or throws if strict).
    fn_name,
    /// this, arguments, new.target, the home object, the active function.
    pseudo,
    private,
    hidden,
};

pub const Var = struct {
    name: *JSString,
    kind: VarKind,
    scope: *Scope,
    /// Read from an inner function, so it lives in an Env instead of a stack slot.
    captured: bool = false,
    /// May be read before initialization, so reads check for the hole.
    needs_tdz: bool = false,
    /// Local slot, or Env slot when captured.
    index: u32 = 0,
    /// Source offset where initialization finishes, for the TDZ analysis.
    init_end: u32 = 0,
    used: bool = false,
    /// import: index into the module's import table.
    import_index: u32 = 0,
    /// A private accessor's or method's kind, for the early errors and the access path.
    private_kind: PrivateKind = .field,
    is_static_private: bool = false,
};

pub const PrivateKind = enum(u8) { field, method, getter, setter, accessor };

pub const ScopeKind = enum(u8) { script, eval, module, function, block, catch_clause, class, for_loop, switch_body, with_body };

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?*Scope,
    func: *FuncInfo,
    vars: std.ArrayList(*Var) = .empty,
    /// Number of captured variables; a scope with any pushes an Env at entry.
    env_size: u32 = 0,
    /// Functions to instantiate at entry, in source order.
    hoisted: std.ArrayList(*Node) = .empty,

    pub fn lookupHere(s: *const Scope, name: *JSString) ?*Var {
        for (s.vars.items) |v| {
            if (v.name == name) return v;
        }
        return null;
    }
};

/// What scope analysis learned about one function.
pub const FuncInfo = struct {
    func: *Func,
    parent: ?*FuncInfo,
    scope: ?*Scope = null,
    nlocals: u32 = 0,
    this_var: ?*Var = null,
    arguments_var: ?*Var = null,
    new_target_var: ?*Var = null,
    home_var: ?*Var = null,
    func_var: ?*Var = null,
    fn_name_var: ?*Var = null,
    uses_this: bool = false,
    uses_super: bool = false,
    has_try: bool = false,
    /// A hidden local holding a return value while `finally` blocks run.
    ret_slot: u32 = 0,
    needs_ret_slot: bool = false,
};

pub const BinOp = enum(u8) { add, sub, mul, div, mod, pow, shl, sar, shr, bit_and, bit_or, bit_xor, lt, le, gt, ge, eq, ne, seq, sne, in, instanceof };
pub const LogOp = enum(u8) { land, lor, nullish };
pub const UnOp = enum(u8) { neg, plus, not, bit_not, typeof, void, delete };

pub const PropKind = enum(u8) { init, shorthand, method, get, set, spread, proto };

pub const Prop = struct {
    kind: PropKind,
    computed: bool = false,
    /// Non-computed key: an atom, or a number already canonicalised to a string atom.
    key_atom: ?*JSString = null,
    key: ?*Node = null,
    value: *Node,
};

pub const Ident = struct {
    name: *JSString,
    binding: ?*Var = null,
    /// The hidden variables of the `with` objects between this use and its binding,
    /// innermost first; each must be asked before the static answer holds.
    with_chain: []*Var = &.{},
};

pub const Template = struct {
    /// Cooked chunks; null for an invalid escape (tagged templates only).
    cooked: []?*JSString,
    raw: []*JSString,
    exprs: []*Node,
};

pub const Decl = struct { target: *Node, init: ?*Node };

pub const ClassMemberKind = enum(u8) { method, get, set, field, static_block };

pub const ClassMember = struct {
    kind: ClassMemberKind,
    is_static: bool,
    computed: bool = false,
    is_private: bool = false,
    key_atom: ?*JSString = null,
    key: ?*Node = null,
    /// The method function; for fields, the initializer expression (or null);
    /// for a static block, its function.
    value: ?*Node = null,
    /// Holds a computed field key, or a private method's closure, between definition and use.
    hidden: ?*Var = null,
    /// The private name's variable.
    private_var: ?*Var = null,
};

pub const Class = struct {
    name: ?*JSString,
    parent: ?*Node,
    ctor: ?*Func,
    members: []ClassMember,
    scope: ?*Scope = null,
    name_var: ?*Var = null,
    /// The binding a class declaration initializes in the enclosing scope.
    outer_binding: ?*Var = null,
    /// Synthetic functions running field initializers and static blocks.
    instance_init: ?*Func = null,
    static_init: ?*Func = null,
    start: u32,
    end: u32,
};

pub const Func = struct {
    name: ?*JSString = null,
    params: []*Node = &.{},
    body: []*Node = &.{},
    /// Arrow function with an expression body.
    expr_body: ?*Node = null,
    is_arrow: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    is_method: bool = false,
    is_getter: bool = false,
    is_setter: bool = false,
    is_class_ctor: bool = false,
    is_derived: bool = false,
    is_default_ctor: bool = false,
    is_expr: bool = false,
    is_decl: bool = false,
    /// A class's field-initializer or static-block function.
    is_class_init: bool = false,
    strict: bool = false,
    simple_params: bool = true,
    has_use_strict: bool = false,
    start: u32 = 0,
    end: u32 = 0,
    info: ?*FuncInfo = null,
    /// For synthetic class-init functions: which class and which members.
    init_class: ?*Class = null,
    init_static: bool = false,
    /// Annex B: the function-scoped var a block-level declaration also assigns.
    annex_b_var: ?*Var = null,
    annex_b_global: bool = false,
    decl_binding: ?*Var = null,
};

pub const ImportEntry = struct {
    /// Name exported by the other module; null for `* as ns`.
    imported: ?*JSString,
    local: *JSString,
    request: u32,
};

pub const ExportEntry = struct {
    /// Exported name; null for `export *`.
    exported: ?*JSString,
    /// Local binding name, for `export {a as b}` and declarations.
    local: ?*JSString = null,
    /// Indirect: name in another module (null with a request means `* as exported`).
    imported: ?*JSString = null,
    request: ?u32 = null,
};

pub const Data = union(enum) {
    // Expressions.
    num: f64,
    str: *JSString,
    bigint: *JSString,
    template: *Template,
    tagged: struct { tag: *Node, tmpl: *Template },
    regex: struct { pattern: *JSString, flags: *JSString },
    ident: *Ident,
    this: *Ident,
    null_lit,
    true_lit,
    false_lit,
    array: []?*Node,
    object: []Prop,
    function: *Func,
    class: *Class,
    unary: struct { op: UnOp, arg: *Node },
    update: struct { inc: bool, prefix: bool, arg: *Node },
    binary: struct { op: BinOp, l: *Node, r: *Node },
    logical: struct { op: LogOp, l: *Node, r: *Node },
    /// `=` has op null; compound assignments carry their binary or logical operator.
    assign: struct { op: ?BinOp = null, log: ?LogOp = null, target: *Node, value: *Node },
    cond: struct { t: *Node, a: *Node, b: *Node },
    call: struct { callee: *Node, args: []*Node, optional: bool = false, has_spread: bool = false },
    new: struct { callee: *Node, args: []*Node, has_spread: bool = false },
    member: struct { obj: *Node, name: *JSString, optional: bool = false },
    index: struct { obj: *Node, idx: *Node, optional: bool = false },
    private_member: struct { obj: *Node, name: *Ident, optional: bool = false },
    private_in: struct { name: *Ident, r: *Node },
    super_member: struct { this: *Ident, home: *Ident, name: *JSString },
    super_index: struct { this: *Ident, home: *Ident, idx: *Node },
    super_call: struct { args: []*Node, has_spread: bool, this: *Ident, func: *Ident, new_target: *Ident },
    spread: *Node,
    seq: []*Node,
    yield: struct { arg: ?*Node, delegate: bool },
    await: *Node,
    /// The root of an optional chain; short-circuits land at its end.
    opt_chain: *Node,
    new_target: *Ident,
    import_meta,
    import_call: *Node,

    // Statements.
    var_decl: struct { kind: VarKind, decls: []Decl },
    func_decl: *Func,
    class_decl: *Class,
    expr_stmt: *Node,
    block: struct { body: []*Node, scope: ?*Scope = null },
    if_stmt: struct { t: *Node, a: *Node, b: ?*Node },
    for_stmt: struct { init: ?*Node, t: ?*Node, update: ?*Node, body: *Node, scope: ?*Scope = null },
    for_in: struct { left: *Node, right: *Node, body: *Node, scope: ?*Scope = null },
    for_of: struct { left: *Node, right: *Node, body: *Node, is_await: bool, scope: ?*Scope = null },
    with_stmt: struct { obj: *Node, body: *Node, scope: ?*Scope = null, hidden: ?*Var = null },
    while_stmt: struct { t: *Node, body: *Node },
    do_while: struct { t: *Node, body: *Node },
    return_stmt: ?*Node,
    break_stmt: ?*JSString,
    continue_stmt: ?*JSString,
    throw_stmt: *Node,
    try_stmt: struct {
        block: *Node,
        param: ?*Node,
        handler: ?*Node,
        finalizer: ?*Node,
        catch_scope: ?*Scope = null,
    },
    switch_stmt: struct { disc: *Node, cases: []Case, scope: ?*Scope = null },
    labeled: struct { label: *JSString, body: *Node },
    empty,
    debugger,
    /// `export default <expr>`: assigns the hidden *default* binding.
    export_default: struct { value: *Node, binding: *Ident },
};

pub const Case = struct { t: ?*Node, body: []*Node };

pub const Node = struct {
    data: Data,
    pos: u32,
    end: u32 = 0,
    paren: bool = false,
};

/// A whole parse: the top function, plus module records for modules.
pub const Program = struct {
    func: *Func,
    is_module: bool = false,
    imports: []ImportEntry = &.{},
    exports: []ExportEntry = &.{},
    requests: []*JSString = &.{},
    has_tla: bool = false,
};
