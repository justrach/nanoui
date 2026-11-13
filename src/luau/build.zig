//! Opt-in Luau module. The default graph never fetches or links Luau.
const std = @import("std");
pub fn add(b: *std.Build, nanoui: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const os = target.result.os.tag;
    if ((os != .macos and os != .linux and os != .windows) or target.result.abi.isAndroid())
        std.debug.panic("nanoui_luau currently supports desktop targets only; leave -Dluau off for mobile", .{});
    const dep = b.lazyDependency("luau", .{}) orelse return;
    const vm = b.addLibrary(.{ .name = "nanoui-luau-vm", .linkage = .static, .use_llvm = true, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }) });
    if (os == .macos and !target.query.isNative()) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            vm.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
            vm.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            vm.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    for ([_][]const u8{ "Common/include", "Ast/include", "Bytecode/include", "Compiler/include", "VM/include" }) |dir| vm.root_module.addIncludePath(dep.path(dir));
    vm.root_module.addCSourceFiles(.{ .root = dep.path(""), .files = &sources, .flags = &.{ "-std=c++17", "-DLUA_USE_LONGJMP=1", "-DLUA_API=extern \"C\"", "-DLUACODE_API=extern \"C\"" } });
    const module = b.addModule("nanoui_luau", .{ .root_source_file = b.path("src/luau/luau.zig"), .target = target, .optimize = optimize });
    module.addImport("nanoui", nanoui);
    module.linkLibrary(vm);
    // The final link compiles libc++ too; it needs the same SDK headers.
    for (vm.root_module.include_dirs.items) |dir| switch (dir) {
        .path_system => |path| module.addSystemIncludePath(path),
        else => {},
    };
    const tests = b.addTest(.{ .root_module = module, .use_llvm = true });
    b.step("test-luau", "Test the optional sandbox and native Luau UI bridge").dependOn(&b.addRunArtifact(tests).step);
    b.step("check-luau", "Compile the optional bridge without executing the target").dependOn(&tests.step);
}
const sources = [_][]const u8{
    "Common/src/BytecodeWire.cpp",
    "Common/src/StringUtils.cpp",
    "Common/src/TimeTrace.cpp",
    "Ast/src/Allocator.cpp",
    "Ast/src/Ast.cpp",
    "Ast/src/Confusables.cpp",
    "Ast/src/Cst.cpp",
    "Ast/src/Lexer.cpp",
    "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",
    "Ast/src/PrettyPrinter.cpp",
    "Bytecode/src/BytecodeBuilder.cpp",
    "Bytecode/src/BytecodeDump.cpp",
    "Bytecode/src/BytecodeGraph.cpp",
    "Bytecode/src/Sccp.cpp",
    "Compiler/src/Compiler.cpp",
    "Compiler/src/Builtins.cpp",
    "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/ConstantFolding.cpp",
    "Compiler/src/CostModel.cpp",
    "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",
    "Compiler/src/ValueTracking.cpp",
    "Compiler/src/lcode.cpp",
    "VM/src/lapi.cpp",
    "VM/src/laux.cpp",
    "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",
    "VM/src/lbuffer.cpp",
    "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",
    "VM/src/lcorolib.cpp",
    "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",
    "VM/src/ldo.cpp",
    "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",
    "VM/src/lgcdebug.cpp",
    "VM/src/linit.cpp",
    "VM/src/lmathlib.cpp",
    "VM/src/lmem.cpp",
    "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",
    "VM/src/loslib.cpp",
    "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",
    "VM/src/lstring.cpp",
    "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",
    "VM/src/ltablib.cpp",
    "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",
    "VM/src/lutf8lib.cpp",
    "VM/src/lveclib.cpp",
    "VM/src/lintlib.cpp",
    "VM/src/lvmexecute.cpp",
    "VM/src/lclass.cpp",
    "VM/src/lclasslib.cpp",
    "VM/src/lvector.cpp",
    "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
};
