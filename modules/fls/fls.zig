//! Fun Language Server (fls) - module root.
//! Re-exports the public API and ensures all sub-module tests are discovered.

pub const globals = @import("globals.zig");
pub const types = @import("types.zig");
pub const protocol = @import("protocol.zig");
pub const uri = @import("uri.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const positions = @import("positions.zig");
pub const token_index = @import("token_index.zig");
pub const ast_index = @import("ast_index.zig");
pub const index = @import("index.zig");

const server_mod = @import("server.zig");
pub const LspServer = server_mod.LspServer;

test {
    // Ensure tests in all sub-modules are discovered by the test runner.
    _ = globals;
    _ = types;
    _ = protocol;
    _ = uri;
    _ = diagnostics;
    _ = positions;
    _ = token_index;
    _ = ast_index;
    _ = index;
    _ = server_mod;
}
