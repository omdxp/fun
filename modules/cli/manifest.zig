const std = @import("std");
const mem = std.mem;

/// A single `[[exe]]` build target: a Fun source file compiled to a binary.
pub const BinTarget = struct {
    name: []const u8,
    path: []const u8,
};

/// A parsed `fun.toml` project manifest.
pub const Manifest = struct {
    allocator: mem.Allocator,
    package_name: []const u8,
    version: []const u8,
    bins: []BinTarget,

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.package_name);
        self.allocator.free(self.version);
        for (self.bins) |b| {
            self.allocator.free(b.name);
            self.allocator.free(b.path);
        }
        self.allocator.free(self.bins);
    }
};

pub const ManifestError = error{
    InvalidManifest,
    MissingPackageSection,
    MissingPackageName,
    MissingBinName,
    MissingBinPath,
};

/// Parses a minimal TOML subset sufficient for `fun.toml`:
/// ```
/// [package]
/// name = "myproject"
/// version = "0.1.0"
///
/// [[exe]]
/// name = "myapp"
/// path = "src/main.fn"
/// ```
///
/// Deliberately narrow: no nested tables, no arrays-of-scalars, no
/// multi-line/escaped strings. Fun's own `imp` already does path-based
/// module resolution, so the manifest only needs to declare BUILD TARGETS
/// (which entry file produces which binary), not an import graph.
pub fn parse(allocator: mem.Allocator, text: []const u8) !Manifest {
    var package_name: ?[]const u8 = null;
    errdefer if (package_name) |v| allocator.free(v);
    var version: ?[]const u8 = null;
    errdefer if (version) |v| allocator.free(v);

    var bins = std.array_list.Managed(BinTarget).init(allocator);
    errdefer {
        for (bins.items) |b| {
            allocator.free(b.name);
            allocator.free(b.path);
        }
        bins.deinit();
    }

    const Section = enum { none, package, bin };
    var section: Section = .none;
    var cur_bin_name: ?[]const u8 = null;
    errdefer if (cur_bin_name) |v| allocator.free(v);
    var cur_bin_path: ?[]const u8 = null;
    errdefer if (cur_bin_path) |v| allocator.free(v);

    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Strip a trailing `# comment` (only outside of quoted strings --
        // fun.toml values are never expected to contain a literal `#`).
        if (mem.indexOfScalar(u8, line, '#')) |ci| {
            line = mem.trim(u8, line[0..ci], " \t");
            if (line.len == 0) continue;
        }

        if (mem.startsWith(u8, line, "[[") and mem.endsWith(u8, line, "]]")) {
            const name = mem.trim(u8, line[2 .. line.len - 2], " \t");
            if (!mem.eql(u8, name, "exe")) return ManifestError.InvalidManifest;
            try flush_bin(allocator, &bins, &cur_bin_name, &cur_bin_path);
            section = .bin;
            continue;
        }
        if (mem.startsWith(u8, line, "[") and mem.endsWith(u8, line, "]")) {
            try flush_bin(allocator, &bins, &cur_bin_name, &cur_bin_path);
            const name = mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (!mem.eql(u8, name, "package")) return ManifestError.InvalidManifest;
            section = .package;
            continue;
        }

        const eq_idx = mem.indexOfScalar(u8, line, '=') orelse return ManifestError.InvalidManifest;
        const key = mem.trim(u8, line[0..eq_idx], " \t");
        const raw_val = mem.trim(u8, line[eq_idx + 1 ..], " \t");
        const val = parse_toml_string(raw_val) orelse return ManifestError.InvalidManifest;

        switch (section) {
            .package => {
                if (mem.eql(u8, key, "name")) {
                    if (package_name) |old| allocator.free(old);
                    package_name = try allocator.dupe(u8, val);
                } else if (mem.eql(u8, key, "version")) {
                    if (version) |old| allocator.free(old);
                    version = try allocator.dupe(u8, val);
                }
            },
            .bin => {
                if (mem.eql(u8, key, "name")) {
                    if (cur_bin_name) |old| allocator.free(old);
                    cur_bin_name = try allocator.dupe(u8, val);
                } else if (mem.eql(u8, key, "path")) {
                    if (cur_bin_path) |old| allocator.free(old);
                    cur_bin_path = try allocator.dupe(u8, val);
                }
            },
            .none => return ManifestError.InvalidManifest,
        }
    }
    try flush_bin(allocator, &bins, &cur_bin_name, &cur_bin_path);

    const pkg_name = package_name orelse return ManifestError.MissingPackageName;
    const pkg_version = version orelse try allocator.dupe(u8, "0.0.0");

    return Manifest{
        .allocator = allocator,
        .package_name = pkg_name,
        .version = pkg_version,
        .bins = try bins.toOwnedSlice(),
    };
}

fn flush_bin(
    allocator: mem.Allocator,
    bins: *std.array_list.Managed(BinTarget),
    cur_bin_name: *?[]const u8,
    cur_bin_path: *?[]const u8,
) !void {
    if (cur_bin_name.* == null and cur_bin_path.* == null) return;
    const name = cur_bin_name.* orelse return ManifestError.MissingBinName;
    const path = cur_bin_path.* orelse {
        allocator.free(name);
        cur_bin_name.* = null;
        return ManifestError.MissingBinPath;
    };
    try bins.append(.{ .name = name, .path = path });
    cur_bin_name.* = null;
    cur_bin_path.* = null;
}

/// Parses a double-quoted TOML string value (`"..."`). Returns null if `raw`
/// isn't a quoted string. No escape-sequence handling -- not needed for
/// plain package names/file paths.
fn parse_toml_string(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

// Tests for this module live in tests/manifest_test.zig (aggregated by
// tests/main_test.zig via `@import("cli").manifest`), not here -- a `test`
// block in a file that's only reachable as a cross-module dependency (like
// this one, `addImport`ed into `cli_module` rather than being a root/
// directly-@import`ed file of any `addTest` step in build.zig) is silently
// never run by `zig build test`, which would be misleading here.
