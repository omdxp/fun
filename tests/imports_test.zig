const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");

test "preload_import_global_symbols finds imported functions" {
    var tp = try codegen.TranspileProcess.init(
        std.testing.allocator,
        "examples/imports/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();

    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "relative.parent",
        null,
    );

    try std.testing.expect(tp.global_symbols.get("parent") != null);
}

test "preload_import_global_symbols supports aliased duplicate exports" {
    var tp = try codegen.TranspileProcess.init(
        std.testing.allocator,
        "examples/imports/alias_collision/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();

    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "mod1",
        "one",
    );
    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "mod2",
        "two",
    );

    try std.testing.expect(tp.global_symbols.get("one__pick") != null);
    try std.testing.expect(tp.global_symbols.get("two__pick") != null);
}
