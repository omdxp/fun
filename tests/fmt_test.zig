const std = @import("std");
const cli = @import("cli");

fn writeTempFnFile(allocator: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.fn", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.fs.cwd().createFile(name, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
    return name;
}

test "-fmt formats file in-place" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun  add(num a,num b) num{ret a+b;}\n" ++
        "//comment\n" ++
        "if true{ret 1;}else{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun add(num a, num b) num {\n" ++
        "    ret a + b;\n" ++
        "}\n" ++
        "//comment\n" ++
        "if true {\n" ++
        "    ret 1;\n" ++
        "} else {\n" ++
        "    ret 2;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}
