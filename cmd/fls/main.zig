const std = @import("std");
const fls = @import("fls");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    // CLI helpers (used by installers / debugging PATH mismatches).
    // Note: fls is normally launched by the VS Code extension with no args (stdio mode).
    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip executable name

    if (args_it.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
            const ver_str = "fls " ++ build_options.version ++ "\n";
            std.Io.File.stdout().writeStreamingAll(init.io, ver_str) catch {};
            return;
        }
        if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            std.Io.File.stdout().writeStreamingAll(
                init.io,
                "Fun Language Server (fls)\n\n" ++
                    "Usage:\n" ++
                    "  fls            Run language server over stdio (LSP)\n" ++
                    "  fls --version  Print version\n" ++
                    "  fls --help     Show this help\n",
            ) catch {};
            return;
        }
    }

    var server = try fls.LspServer.init(allocator, init.io);
    defer server.deinit();
    try server.run();
}
