const std = @import("std");

pub var g_runtime_io: ?std.Io = null;

pub fn globalIo() std.Io {
    return g_runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

pub fn nowMs() i64 {
    const ts = std.Io.Clock.Timestamp.now(globalIo(), .real);
    return @intCast(@divFloor(ts.raw.nanoseconds, std.time.ns_per_ms));
}

pub fn nowNs() i128 {
    const ts = std.Io.Clock.Timestamp.now(globalIo(), .real);
    return ts.raw.nanoseconds;
}

pub fn fileReadAlloc(allocator: std.mem.Allocator, f: std.Io.File, max: usize) ![]u8 {
    var read_buf: [65536]u8 = undefined;
    var fr = f.reader(globalIo(), &read_buf);
    return fr.interface.allocRemaining(allocator, .limited(max));
}
