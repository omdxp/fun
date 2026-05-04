const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");
const types = @import("types.zig");
const positions_mod = @import("positions.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const Position = types.Position;
const Range = types.Range;
const TokenLite = types.TokenLite;
const SymbolLite = types.SymbolLite;
const SymbolKind = types.SymbolKind;

const posInRange = positions_mod.posInRange;
const rangeStartGreater = positions_mod.rangeStartGreater;
const rangeFromTokenPos = positions_mod.rangeFromTokenPos;

pub fn fixAstVariableRanges(tokens: []const TokenLite, symbols: *ArrayList(SymbolLite)) void {
    for (symbols.items) |*s| {
        if (s.kind != .variable) continue;

        var best: ?Range = null;
        for (tokens) |t| {
            if (t.kind != .identifier) continue;
            if (!std.mem.eql(u8, t.text, s.name)) continue;

            if (s.container_fn_range) |cr| {
                if (!posInRange(t.range.start, cr)) continue;
            }

            if (t.range.start.line < s.decl_range.start.line) continue;
            if (t.range.start.line == s.decl_range.start.line and t.range.start.character < s.decl_range.start.character) continue;

            if (best == null or rangeStartGreater(best.?, t.range)) {
                best = t.range;
            }
        }

        if (best) |r| {
            s.selection_range = r;
            s.decl_range = r;
        }
    }
}

pub const AstEnrichment = struct {
    fn_sig_by_name: std.StringHashMap([]const u8),
    fn_rtype_by_name: std.StringHashMap([]const u8),
    member_sig_by_key: std.StringHashMap([]const u8),
    member_rtype_by_key: std.StringHashMap([]const u8),
    field_type_by_key: std.StringHashMap([]const u8),

    fn init(allocator: Allocator) AstEnrichment {
        return .{
            .fn_sig_by_name = std.StringHashMap([]const u8).init(allocator),
            .fn_rtype_by_name = std.StringHashMap([]const u8).init(allocator),
            .member_sig_by_key = std.StringHashMap([]const u8).init(allocator),
            .member_rtype_by_key = std.StringHashMap([]const u8).init(allocator),
            .field_type_by_key = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

pub fn appendDTypeFull(buf: *ArrayList(u8), dt: anytype) !void {
    const dtype = if (@typeInfo(@TypeOf(dt)) == .pointer) dt.* else dt;
    try buf.appendSlice(dtype.type_str.items);
    if (@hasField(@TypeOf(dtype), "generic_args")) {
        if (dtype.generic_args) |gargs| {
            try buf.append('<');
            for (gargs.items(), 0..) |ga, i| {
                if (i != 0) try buf.appendSlice(", ");
                try appendDTypeFull(buf, ga.*);
            }
            try buf.append('>');
        }
    }
    var i: usize = 0;
    while (i < dtype.pointer_depth) : (i += 1) {
        try buf.append('*');
    }
    if (@hasField(@TypeOf(dtype), "flags")) {
        if (dtype.flags) |flags| {
            if (flags.is_array) {
                // Use array_depth for the count of [] to emit when available,
                // falling back to bracket count or 1 for backward compatibility.
                const bracket_count: usize = blk: {
                    if (@hasField(@TypeOf(dtype), "array_depth") and dtype.array_depth > 0) {
                        break :blk dtype.array_depth;
                    }
                    if (@hasField(@TypeOf(dtype), "array")) {
                        if (dtype.array) |arr| {
                            break :blk if (arr.brackets.is_empty()) 1 else arr.brackets.count;
                        }
                    }
                    break :blk 1;
                };
                var j: usize = 0;
                while (j < bracket_count) : (j += 1) {
                    try buf.appendSlice("[]");
                }
                return;
            }
        }
    }
}

pub fn enrichSymbolsFromAst(allocator: Allocator, symbols: *ArrayList(SymbolLite), tp: *codegen.TranspileProcess) !void {
    var enrich = AstEnrichment.init(allocator);

    const dtypeStringOwned = struct {
        fn build(a: Allocator, dt: anytype) ![]u8 {
            var buf = ArrayList(u8).init(a);
            errdefer buf.deinit();
            try appendDTypeFull(&buf, dt);
            return try buf.toOwnedSlice();
        }
    };

    // Build lookup tables from the parsed AST.
    for (tp.nodes.items()) |*n| {
        if (n.node_variant == null) continue;
        switch (n.type) {
            .Function => {
                const fnv = n.node_variant.?.function;
                const name_al = fnv.name orelse continue;
                const fn_name = name_al.items;

                if (!enrich.fn_sig_by_name.contains(fn_name)) {
                    const sig = try buildSignatureFromAst(allocator, fn_name, fnv, true);
                    try enrich.fn_sig_by_name.put(fn_name, sig);
                }

                if (fnv.rtype) |rt| {
                    if (!enrich.fn_rtype_by_name.contains(fn_name)) {
                        const rts = try dtypeStringOwned.build(allocator, rt);
                        try enrich.fn_rtype_by_name.put(fn_name, rts);
                    }
                }
            },
            .Compound => {
                const cv = n.node_variant.?.compound;
                const type_name = cv.name.items;

                for (cv.fields.items()) |f| {
                    const field_name = f.name.items;
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, field_name });
                    if (!enrich.field_type_by_key.contains(key)) {
                        const fts = try dtypeStringOwned.build(allocator, f.dtype.*);
                        try enrich.field_type_by_key.put(key, fts);
                    }
                }
            },
            .Quirk => {
                const qv = n.node_variant.?.quirk;
                const quirk_name = qv.name.items;

                for (qv.methods.items()) |m| {
                    const mname = m.name.items;
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ quirk_name, mname });
                    if (!enrich.member_sig_by_key.contains(key)) {
                        const sig = try buildQuirkMethodSignatureFromAst(allocator, m);
                        try enrich.member_sig_by_key.put(key, sig);
                    }
                    if (!enrich.member_rtype_by_key.contains(key)) {
                        const rts = try dtypeStringOwned.build(allocator, m.rtype);
                        try enrich.member_rtype_by_key.put(key, rts);
                    }
                }
            },
            .Impl => {
                const iv = n.node_variant.?.impl;
                const type_name = iv.type_name.items;

                for (iv.methods.items()) |mnode| {
                    if (mnode.type != .Function or mnode.node_variant == null) continue;
                    const mf = mnode.node_variant.?.function;
                    const name_al = mf.name orelse continue;
                    // Impl method names are stored as generated names:
                    // - Plain: `<Type>__<method>`
                    // - Quirk: `<Type>__<Quirk>__<method>`
                    // For LSP UX we key by `<Type>.<method>`.
                    const gen = name_al.items;
                    const mname = if (std.mem.lastIndexOf(u8, gen, "__")) |cut| gen[cut + 2 ..] else gen;

                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, mname });
                    if (!enrich.member_sig_by_key.contains(key)) {
                        const sig = try buildSignatureFromAst(allocator, mname, mf, false);
                        try enrich.member_sig_by_key.put(key, sig);
                    }
                    if (mf.rtype) |rt| {
                        if (!enrich.member_rtype_by_key.contains(key)) {
                            const rts = try dtypeStringOwned.build(allocator, rt);
                            try enrich.member_rtype_by_key.put(key, rts);
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Apply enrichment to the token-derived symbols.
    for (symbols.items) |*s| {
        if (s.kind == .function) {
            if (s.detail == null) {
                if (enrich.fn_sig_by_name.get(s.name)) |sig| s.detail = sig;
            }
            if (s.value_type == null) {
                if (enrich.fn_rtype_by_name.get(s.name)) |rt| s.value_type = rt;
            }
            continue;
        }

        if (s.container_type) |ct| {
            // Field/property type.
            if (s.value_type == null and (s.kind == .field or s.kind == .property)) {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ct, s.name }) catch null;
                if (key) |k| {
                    if (enrich.field_type_by_key.get(k)) |ft| s.value_type = ft;
                }
            }

            // Method signature/return type.
            if (s.detail == null and (s.kind == .method or s.kind == .function)) {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ct, s.name }) catch null;
                if (key) |k| {
                    if (enrich.member_sig_by_key.get(k)) |ms| s.detail = ms;
                    if (s.value_type == null) {
                        if (enrich.member_rtype_by_key.get(k)) |rt| s.value_type = rt;
                    }
                }
            }
        }

        if (s.container_fn_range) |fr| {
            _ = fr;
        }
    }
}

pub fn buildSignatureFromAst(
    allocator: Allocator,
    name: []const u8,
    fnv: anytype,
    include_fun_prefix: bool,
) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const is_async_fn = @hasField(@TypeOf(fnv), "is_async") and fnv.is_async;
    if (is_async_fn) {
        try buf.appendSlice("async ");
    }

    if (include_fun_prefix) {
        try buf.print("fun {s}", .{name});
    } else {
        try buf.print("{s}", .{name});
    }
    if (@hasField(@TypeOf(fnv), "type_params")) {
        if (fnv.type_params) |params| {
            try buf.append('<');
            for (params.items(), 0..) |p, i| {
                if (i != 0) try buf.appendSlice(", ");
                try buf.appendSlice(p.items);
            }
            try buf.append('>');
        }
    }

    try buf.append('(');

    if (fnv.args) |args| {
        var first: bool = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const av = a.node_variant.?.variable;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try appendDTypeFull(&buf, av.type);
            try buf.print(" {s}", .{av.name.items});
        }
    }

    if (@hasField(@TypeOf(fnv), "is_variadic") and fnv.is_variadic) {
        if (fnv.args) |args| {
            if (args.items().len != 0) try buf.appendSlice(", ");
        }
        try buf.appendSlice("...");
    }

    try buf.append(')');
    if (fnv.rtype) |rt| {
        try buf.append(' ');
        try appendDTypeFull(&buf, rt);
    }
    return try buf.toOwnedSlice();
}

pub fn buildQuirkMethodSignatureFromAst(allocator: Allocator, m: ast.QuirkMethodSig) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (m.is_async) {
        try buf.appendSlice("async ");
    }
    try buf.print("{s}(", .{m.name.items});
    var first: bool = true;
    for (m.args.items()) |a| {
        if (!first) try buf.appendSlice(", ");
        first = false;
        try appendDTypeFull(&buf, a.dtype);
        try buf.print(" {s}", .{a.name.items});
    }
    try buf.append(')');
    try buf.append(' ');
    try appendDTypeFull(&buf, m.rtype);
    return try buf.toOwnedSlice();
}

pub fn makeGenericTypeInsertText(allocator: Allocator, name: []const u8, detail_opt: ?[]const u8) !?[]const u8 {
    const det = detail_opt orelse return null;
    const open_opt = std.mem.indexOfScalar(u8, det, '<') orelse return null;
    const close_rel_opt = std.mem.indexOfScalar(u8, det[open_opt + 1 ..], '>') orelse return null;
    const close_idx = open_opt + 1 + close_rel_opt;
    if (close_idx <= open_opt + 1) return null;

    const params = std.mem.trim(u8, det[open_opt + 1 .. close_idx], " \t\r\n");
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(name);
    try buf.append('<');
    if (params.len != 0) try buf.appendSlice(params);
    try buf.append('>');
    return try buf.toOwnedSlice();
}

pub fn collectSymbolsFromTopLevel(allocator: Allocator, out: *ArrayList(SymbolLite), n: ast.Node) !void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .Variable => {
            const v = n.node_variant.?.variable;
            const name = v.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else return;

            var detail_buf = ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try appendDTypeFull(&detail_buf, v.type);
            try detail_buf.print(" {s}", .{name});

            var vtype_buf = ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            try appendDTypeFull(&vtype_buf, v.type);

            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = try allocator.dupe(u8, vtype_buf.items),
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Function => {
            const fnv = n.node_variant.?.function;
            if (fnv.name == null) return;
            const name = fnv.name.?.items;
            const decl_range = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };

            const detail = try formatFunctionSignature(allocator, name, fnv);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .function,
                .decl_range = decl_range,
                .selection_range = decl_range,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = detail,
            });

            const container = if (fnv.body) |b| if (b.pos) |bp| rangeFromTokenPos(bp) else decl_range else decl_range;
            if (fnv.body) |b| {
                try collectLocalVars(allocator, out, b, container);
            }
        },
        .Compound => {
            const c = n.node_variant.?.compound;
            const name = c.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
            var detail_buf = ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try detail_buf.print("compound {s}", .{name});
            if (c.type_params) |params| {
                try detail_buf.append('<');
                for (params.items(), 0..) |p, i| {
                    if (i != 0) try detail_buf.appendSlice(", ");
                    try detail_buf.appendSlice(p.items);
                }
                try detail_buf.append('>');
            }
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .struct_,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Quirk => {
            const q = n.node_variant.?.quirk;
            const name = q.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
            var detail_buf = ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try detail_buf.print("quirk {s}", .{name});
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .interface,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Impl => {
            // Skip impl methods here: the AST stores generated method names
            // (`Type__method` / `Type__Quirk__method`), while the lexer scan has
            // the user-facing method name and better positioning.
        },
        else => {},
    }
}

pub fn formatFunctionSignature(allocator: Allocator, name: []const u8, fnv: anytype) ![]u8 {
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    if (@hasField(@TypeOf(fnv), "is_async") and fnv.is_async) {
        try buf.appendSlice("async ");
    }
    try buf.print("fun {s}", .{name});

    if (@hasField(@TypeOf(fnv), "type_params")) {
        if (fnv.type_params) |params| {
            try buf.append('<');
            for (params.items(), 0..) |p, i| {
                if (i != 0) try buf.appendSlice(", ");
                try buf.appendSlice(p.items);
            }
            try buf.append('>');
        }
    }

    try buf.append('(');

    if (fnv.args) |args| {
        var first = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const vv = a.node_variant.?.variable;
            const arg_name = vv.name.items;
            const dt = vv.type.*;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try appendDTypeFull(&buf, dt);
            try buf.print(" {s}", .{arg_name});
        }
    }
    if (fnv.is_variadic) {
        if (fnv.args != null and fnv.args.?.items().len != 0) try buf.appendSlice(", ");
        try buf.appendSlice("...");
    }
    try buf.append(')');
    if (fnv.rtype) |rt| {
        try buf.append(' ');
        try appendDTypeFull(&buf, rt);
    }
    return buf.toOwnedSlice();
}

pub fn collectLocalVars(allocator: Allocator, out: *ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .Variable => {
            const v = n.node_variant.?.variable;
            const name = v.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else return;
            var detail_buf = ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try appendDTypeFull(&detail_buf, v.type);
            try detail_buf.print(" {s}", .{name});

            var vtype_buf = ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            try appendDTypeFull(&vtype_buf, v.type);

            const det = try detail_buf.toOwnedSlice();
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_fn_range = container_fn_range,
                .container_type = null,
                .value_type = try allocator.dupe(u8, vtype_buf.items),
                .detail = det,
            });
        },
        .Body => {
            const b = n.node_variant.?.body;
            for (b.statements.items()) |s| {
                try collectLocalVars(allocator, out, s, container_fn_range);
            }
        },
        .StatementIf, .StatementElseIf, .StatementElse, .StatementFor, .StatementFit, .StatementCase, .StatementDefault, .StatementReturn => {
            // Walk common statement subtrees.
            // We only need locals; a best-effort recursion is fine.
            try collectLocalVarsFromStatement(allocator, out, n, container_fn_range);
        },
        .Expression, .ExpressionParenthesis, .Unary, .Tenary, .Bracket => {
            try collectLocalVarsFromExpression(allocator, out, n, container_fn_range);
        },
        else => {},
    }
}

pub fn collectLocalVarsFromStatement(allocator: Allocator, out: *ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .StatementReturn => try collectLocalVars(allocator, out, n.node_variant.?.statement.return_stmt, container_fn_range),
        .StatementDefer => {
            const st = n.node_variant.?.statement.defer_stmt;
            try collectLocalVars(allocator, out, st.body, container_fn_range);
        },
        .StatementIf => {
            const st = n.node_variant.?.statement;
            _ = st;
        },
        .StatementElseIf, .StatementElse, .StatementFor, .StatementFit, .StatementCase, .StatementDefault => {
            // For now, rely on expression/body recursion below if these nodes contain bodies.
        },
        else => {},
    }
    // Generic recursion: attempt to walk known child pointers if present.
    if (n.node_variant) |v| {
        switch (v) {
            .statement => |st| {
                switch (st) {
                    .return_stmt => |rn| try collectLocalVars(allocator, out, rn, container_fn_range),
                    .defer_stmt => |dn| try collectLocalVars(allocator, out, dn.body, container_fn_range),
                    .for_stmt => |fs| switch (fs) {
                        .cond => |c| {
                            if (c.condition) |cond| try collectLocalVars(allocator, out, cond, container_fn_range);
                            try collectLocalVars(allocator, out, c.body, container_fn_range);
                        },
                        .range => |r| {
                            try collectLocalVars(allocator, out, r.range, container_fn_range);
                            try collectLocalVars(allocator, out, r.body, container_fn_range);
                        },
                        .iter => |it| {
                            try collectLocalVars(allocator, out, it.iterable, container_fn_range);
                            try collectLocalVars(allocator, out, it.body, container_fn_range);
                        },
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn collectLocalVarsFromExpression(allocator: Allocator, out: *ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.node_variant.?) {
        .exp => |e| {
            if (e.left) |l| try collectLocalVars(allocator, out, l, container_fn_range);
            if (e.right) |r| try collectLocalVars(allocator, out, r, container_fn_range);
        },
        .paren => |p| try collectLocalVars(allocator, out, p.exp, container_fn_range),
        .unary => |u| try collectLocalVars(allocator, out, u.operand, container_fn_range),
        .tenary => |t| {
            try collectLocalVars(allocator, out, t.condition, container_fn_range);
            try collectLocalVars(allocator, out, t.true, container_fn_range);
            try collectLocalVars(allocator, out, t.false, container_fn_range);
        },
        .bracket => |b| try collectLocalVars(allocator, out, b.inner, container_fn_range),
        else => {},
    }
}

test "fls completion: generic insert text helper" {
    const allocator = std.testing.allocator;

    const ins = try makeGenericTypeInsertText(allocator, "Option", "compound Option<T>");
    defer if (ins) |s| allocator.free(s);
    try std.testing.expect(ins != null);
    try std.testing.expect(std.mem.eql(u8, ins.?, "Option<T>"));

    const ins_multi = try makeGenericTypeInsertText(allocator, "Pair", "compound Pair<A, B>");
    defer if (ins_multi) |s| allocator.free(s);
    try std.testing.expect(ins_multi != null);
    try std.testing.expect(std.mem.eql(u8, ins_multi.?, "Pair<A, B>"));

    const ins2 = try makeGenericTypeInsertText(allocator, "Point", "compound Point");
    defer if (ins2) |s| allocator.free(s);
    try std.testing.expect(ins2 == null);
}
