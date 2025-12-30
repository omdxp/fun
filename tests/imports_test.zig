const std = @import("std");
const codegen = @import("codegen");

test "preload_import_global_symbols finds imported functions" {
    var tp = try codegen.TranspileProcess.init(
        std.testing.allocator,
        "examples/imports/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();

    try tp.preload_import_global_symbols("relative.parent");

    try std.testing.expect(tp.global_symbols.get("parent") != null);
}
