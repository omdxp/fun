const std = @import("std");
const fls = @import("fls");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    // `init.gpa` is `std.heap.DebugAllocator` (safety checks + a stack-trace
    // capture on every single allocation) whenever the binary is built in
    // `.Debug` mode -- observed directly causing the language server to sit
    // pegged at ~100% CPU for tens of minutes at a time on this repo's now-
    // large workspace, since fls's own resolution paths (e.g. inlay-hint
    // callee-signature lookup) are allocation-heavy and every one of those
    // allocations was paying for a full stack unwind. `smp_allocator` is a
    // fast, thread-safe allocator with none of that overhead -- used
    // unconditionally here (rather than relying on `-Doptimize` being
    // exactly right at every future build) since fls is never the thing
    // being debugged when its OWN allocator misbehaves; real leak/UB
    // debugging of the server happens in the Debug-mode unit test binary,
    // not this shipped executable.
    const allocator = std.heap.smp_allocator;
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
