const std = @import("std");

comptime {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("ast_test.zig");
    _ = @import("semantics_test.zig");
    _ = @import("codegen_test.zig");
    _ = @import("utils_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("fmt_test.zig");
    _ = @import("imports_test.zig");
    _ = @import("for_test.zig");
    _ = @import("fit_exhaustive_test.zig");
    _ = @import("typecheck_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}
