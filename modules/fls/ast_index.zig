const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");
const dt_mod = @import("semantics").dtype;
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
            .Enum => {
                // Surface data-carrying variant payloads for hover/completion:
                // register a per-variant "signature" like `Circle(num)` or
                // `Rect(num, num)` under `Enum.Variant`. Payload-free variants get
                // a bare `Variant` entry. This makes IDE hover on a tagged-union
                // variant show its payload types.
                const ev = n.node_variant.?.enum_decl;
                const enum_name = ev.name.items;
                for (ev.variants.items()) |variant| {
                    const vname = variant.name.items;
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ enum_name, vname });
                    if (enrich.member_sig_by_key.contains(key)) continue;
                    var sig = ArrayList(u8).init(allocator);
                    errdefer sig.deinit();
                    try sig.appendSlice(enum_name);
                    try sig.append('.');
                    try sig.appendSlice(vname);
                    if (variant.payload) |payload| {
                        try sig.append('(');
                        for (payload.items(), 0..) |pt, i| {
                            if (i != 0) try sig.appendSlice(", ");
                            try appendDTypeFull(&sig, pt.*);
                        }
                        try sig.append(')');
                    }
                    try enrich.member_sig_by_key.put(key, try sig.toOwnedSlice());
                    // The variant's "result type" is the enum itself.
                    if (!enrich.member_rtype_by_key.contains(key)) {
                        try enrich.member_rtype_by_key.put(key, try allocator.dupe(u8, enum_name));
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

            // Data-carrying enum variant payload signature (e.g. `Shape.Circle(num)`).
            // Only attach it when the variant actually has a payload (the sig then
            // differs from the bare `Enum.Variant`) AND there's no trailing doc
            // comment already occupying `.detail`. The render sites distinguish a
            // sig from a comment by testing for the `Enum.` prefix.
            if (s.detail == null and s.kind == .enumMember) {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ct, s.name }) catch null;
                if (key) |k| {
                    if (enrich.member_sig_by_key.get(k)) |ms| {
                        // Skip payload-free variants: their sig is just `Enum.Variant`,
                        // which the plain render already produces.
                        var prefix_buf: [256]u8 = undefined;
                        const plain = std.fmt.bufPrint(&prefix_buf, "{s}.{s}", .{ ct, s.name }) catch "";
                        if (!std.mem.eql(u8, ms, plain)) s.detail = ms;
                    }
                }
            }
        }

        if (s.container_fn_range) |fr| {
            _ = fr;
        }
    }
}

// Render a function's `<T, U, ...>` generic clause, including each param's
// declared constraint bound (`<T: A | B>`) so the signature matches how a
// constrained generic COMPOUND's hover already renders (`Boxed<T: num | str>`).
// A constrained param's forced instantiations are recorded as the Cartesian
// product of every param's bound set; the bounds for param `i` are the
// distinct values at index `i` across every combo, in first-seen order.
fn appendTypeParamsWithConstraints(buf: *ArrayList(u8), allocator: Allocator, fnv: anytype) !void {
    if (!@hasField(@TypeOf(fnv), "type_params")) return;
    const params = fnv.type_params orelse return;
    try buf.append('<');
    for (params.items(), 0..) |p, i| {
        if (i != 0) try buf.appendSlice(", ");
        try buf.appendSlice(p.items);
        if (@hasField(@TypeOf(fnv), "type_param_forced_insts")) {
            if (fnv.type_param_forced_insts) |insts| {
                var seen = ArrayList([]const u8).init(allocator);
                defer seen.deinit();
                for (insts.items()) |combo| {
                    const combo_items = combo.items();
                    if (i >= combo_items.len) continue;
                    const bound_name = combo_items[i].items;
                    var already: bool = false;
                    for (seen.items) |s| {
                        if (std.mem.eql(u8, s, bound_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) seen.append(bound_name) catch {};
                }
                if (seen.items.len != 0) {
                    try buf.appendSlice(": ");
                    for (seen.items, 0..) |bound_name, bi| {
                        if (bi != 0) try buf.appendSlice(" | ");
                        try buf.appendSlice(bound_name);
                    }
                }
            }
        }
    }
    try buf.append('>');
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
    try appendTypeParamsWithConstraints(&buf, allocator, fnv);

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

    try appendTypeParamsWithConstraints(&buf, allocator, fnv);

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

/// Extract `Enum.Variant` (or just `Variant`) from a fit-arm condition node — the
/// pattern written before `->`. Handles `Shape.Circle` (Expression `.`), a bare
/// `Circle` (Identifier), and the dot-shorthand `.Circle` (Expression `.` with a
/// blank/empty left). Returns the variant name; the enum name (if present) is
/// returned via `enum_out`.
fn fitConditionVariantName(cond: *ast.Node, enum_out: *?[]const u8) ?[]const u8 {
    enum_out.* = null;
    if (cond.node_variant == null) return null;
    switch (cond.type) {
        .Identifier => {
            if (cond.data) |d| if (d == .sval) return d.sval.items;
            return null;
        },
        .Expression => {
            const e = cond.node_variant.?.exp;
            if (!std.mem.eql(u8, e.op, ".")) return null;
            const right = e.right orelse return null;
            const vname = if (right.type == .Identifier and right.data != null and right.data.? == .sval) right.data.?.sval.items else return null;
            if (e.left) |l| {
                if (l.type == .Identifier and l.data != null and l.data.? == .sval) enum_out.* = l.data.?.sval.items;
            }
            return vname;
        },
        else => return null,
    }
}

/// Walk a node subtree for `fit` statements and, for each destructuring arm
/// (`Enum.Variant(a, b) -> { ... }`), index the binding names (`a`, `b`) as typed
/// local variables scoped to the arm body. The payload types come from
/// `payload_by_key` (`"Enum.Variant"` -> positional payload dtypes). This is what
/// gives hover and completion on a matched payload binding its real type.
fn collectFitBindingLocals(
    allocator: Allocator,
    out: *ArrayList(SymbolLite),
    n: *ast.Node,
    payload_by_key: *const std.StringHashMap([]const *dt_mod.DataType),
    variant_to_enum: *const std.StringHashMap([]const u8),
    enum_type_params: *const std.StringHashMap([]const []const u8),
    fn_body: *ast.Node,
) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .Body => {
            for (n.node_variant.?.body.statements.items()) |s| {
                try collectFitBindingLocals(allocator, out, s, payload_by_key, variant_to_enum, enum_type_params, fn_body);
            }
        },
        .StatementFit => {
            const fitv = n.node_variant.?.statement.fit_stmt;
            // The subject's concrete generic args (e.g. `Result<JsonValue>`), used to
            // substitute a generic variant payload param. Resolved best-effort.
            const subject_dt = fitSubjectGenericType(fitv.exp, fn_body);
            for (fitv.branches.items()) |branch| {
                // Recurse into the arm body for nested fits regardless of bindings.
                try collectFitBindingLocals(allocator, out, branch.body, payload_by_key, variant_to_enum, enum_type_params, fn_body);

                const binds = branch.bindings orelse continue;
                if (binds.count == 0) continue;
                const cond = branch.condition orelse continue;

                var enum_name: ?[]const u8 = null;
                const vname = fitConditionVariantName(cond, &enum_name) orelse continue;

                // Resolve the variant's payload types. Prefer the qualified key
                // `Enum.Variant`; fall back to the unique `Variant` (dot-shorthand).
                const resolved_enum = enum_name orelse (variant_to_enum.get(vname) orelse continue);
                const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ resolved_enum, vname });
                defer allocator.free(key);
                const payload = payload_by_key.get(key) orelse continue;

                const arm_range = if (branch.body.pos) |bp| rangeFromTokenPos(bp) else continue;

                // One typed local per positional binding (positions beyond the
                // payload arity are skipped rather than mis-typed).
                for (binds.items(), 0..) |bind_name, i| {
                    if (i >= payload.len) break;
                    const pt = payload[i];
                    const name = bind_name.items;
                    if (name.len == 0) continue;

                    // Substitute a generic payload param (`T`) with the subject's
                    // concrete arg (`Result<JsonValue>.Ok(T)` -> binding is `JsonValue`).
                    const eff = substitutedPayloadType(pt, resolved_enum, subject_dt, enum_type_params) orelse pt;

                    var vtype_buf = ArrayList(u8).init(allocator);
                    defer vtype_buf.deinit();
                    try appendDTypeFull(&vtype_buf, eff.*);

                    var detail_buf = ArrayList(u8).init(allocator);
                    errdefer detail_buf.deinit();
                    try appendDTypeFull(&detail_buf, eff.*);
                    try detail_buf.print(" {s}", .{name});

                    try out.append(.{
                        .name = try allocator.dupe(u8, name),
                        .kind = .variable,
                        .decl_range = arm_range,
                        .selection_range = arm_range,
                        .container_fn_range = arm_range, // scope to the arm body
                        .container_type = null,
                        .value_type = try allocator.dupe(u8, vtype_buf.items),
                        .detail = try detail_buf.toOwnedSlice(),
                    });
                }
            }
        },
        else => {
            // Walk other statement/expression children that may hold a `fit`.
            if (n.node_variant) |v| switch (v) {
                .statement => |st| switch (st) {
                    .for_stmt => |fs| switch (fs) {
                        .cond => |c| try collectFitBindingLocals(allocator, out, c.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                        .range => |r| try collectFitBindingLocals(allocator, out, r.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                        .iter => |it| try collectFitBindingLocals(allocator, out, it.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                    },
                    .if_stmt => |ifs| try collectFitBindingLocals(allocator, out, ifs.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                    .elif_stmt => |es| try collectFitBindingLocals(allocator, out, es.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                    .else_stmt => |es| try collectFitBindingLocals(allocator, out, es.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                    .defer_stmt => |dn| try collectFitBindingLocals(allocator, out, dn.body, payload_by_key, variant_to_enum, enum_type_params, fn_body),
                    else => {},
                },
                else => {},
            };
        },
    }
}

/// When `pt` is a bare type parameter of `resolved_enum` (e.g. `T` of `Result<T>`),
/// and the fit subject's concrete type is known (`Result<JsonValue>`), return the
/// substituted concrete payload type (`JsonValue`). Returns null when no substitution
/// applies (concrete payloads, unknown subject, arity mismatch) — caller uses `pt`.
fn substitutedPayloadType(
    pt: *dt_mod.DataType,
    resolved_enum: []const u8,
    subject_dt: ?*const dt_mod.DataType,
    enum_type_params: *const std.StringHashMap([]const []const u8),
) ?*dt_mod.DataType {
    const sdt = subject_dt orelse return null;
    const gargs = sdt.generic_args orelse return null;
    // The payload must be a bare named type with no generic args / pointer / array.
    if (pt.type != null and pt.type != .Unknown) return null;
    if (pt.generic_args != null) return null;
    if (pt.pointer_depth != 0) return null;
    if (pt.type_str.items.len == 0) return null;
    const params = enum_type_params.get(resolved_enum) orelse return null;
    if (params.len != gargs.count) return null;
    for (params, 0..) |p, i| {
        if (std.mem.eql(u8, p, pt.type_str.items)) return gargs.items()[i];
    }
    return null;
}

/// Build payload + variant->enum maps from all top-level enum declarations, then
/// index every fit-arm payload binding across all function bodies as a typed local.
/// Call after the main symbol collection with the full top-level node list.
pub fn appendFitBindingLocals(allocator: Allocator, out: *ArrayList(SymbolLite), nodes: []const ast.Node) Allocator.Error!void {
    var payload_by_key = std.StringHashMap([]const *dt_mod.DataType).init(allocator);
    defer payload_by_key.deinit();
    var variant_to_enum = std.StringHashMap([]const u8).init(allocator);
    defer variant_to_enum.deinit();
    var ambiguous = std.StringHashMap(void).init(allocator);
    defer ambiguous.deinit();
    // enum name -> its type-parameter spellings (e.g. `Result` -> ["T"]). Used to
    // substitute a generic variant payload (`Ok(T)`) with the fit subject's concrete
    // arg (`Result<JsonValue>` -> the `doc` binding is `JsonValue`, not a bare `T`).
    var enum_type_params = std.StringHashMap([]const []const u8).init(allocator);
    defer enum_type_params.deinit();

    for (nodes) |n| {
        if (n.type != .Enum or n.node_variant == null) continue;
        const ev = n.node_variant.?.enum_decl;
        const enum_name = ev.name.items;
        if (ev.type_params) |tps| {
            const names = try allocator.alloc([]const u8, tps.count);
            for (tps.items(), 0..) |tp, i| names[i] = tp.items;
            try enum_type_params.put(enum_name, names);
        }
        for (ev.variants.items()) |variant| {
            const payload = variant.payload orelse continue;
            const vname = variant.name.items;
            const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ enum_name, vname });
            // Snapshot the payload dtypes into a plain slice (decoupled from the
            // Vector's internal storage).
            const slice = try allocator.dupe(*dt_mod.DataType, payload.items());
            try payload_by_key.put(key, slice);
            // Track variant->enum for dot-shorthand; mark ambiguous if two enums
            // share a variant name (then shorthand can't disambiguate).
            if (variant_to_enum.contains(vname)) {
                try ambiguous.put(vname, {});
            } else {
                try variant_to_enum.put(vname, enum_name);
            }
        }
    }
    var it = ambiguous.keyIterator();
    while (it.next()) |k| _ = variant_to_enum.remove(k.*);

    for (nodes) |n| {
        if (n.type != .Function or n.node_variant == null) continue;
        const fnv = n.node_variant.?.function;
        if (fnv.body) |b| {
            try collectFitBindingLocals(allocator, out, b, &payload_by_key, &variant_to_enum, &enum_type_params, b);
        }
    }
}

/// Find the declared type of a local variable `name` within a function body subtree.
/// Returns the variable's DataType when it carries generic args (e.g. `Result<JsonValue>`),
/// else null. Best-effort: only `Type<Args> name [= ...]` local declarations are resolved.
fn findVarDeclTypeInBody(name: []const u8, n: *ast.Node) ?*const dt_mod.DataType {
    if (n.node_variant == null) return null;
    switch (n.type) {
        .Variable => {
            const v = n.node_variant.?.variable;
            if (v.name.items.len != 0 and std.mem.eql(u8, v.name.items, name) and v.type.generic_args != null) {
                return v.type;
            }
            return null;
        },
        .Body => {
            for (n.node_variant.?.body.statements.items()) |s| {
                if (findVarDeclTypeInBody(name, s)) |dt| return dt;
            }
            return null;
        },
        else => return null,
    }
}

/// Given a fit subject expression and the enclosing function body, resolve the
/// subject's concrete generic args. Handles a bare-identifier subject (`fit r {`)
/// by locating `r`'s declaration. Returns the DataType (with generic_args) or null.
fn fitSubjectGenericType(subject: *ast.Node, fn_body: *ast.Node) ?*const dt_mod.DataType {
    if (subject.type != .Identifier) return null;
    const sname = if (subject.data) |d| (if (d == .sval) d.sval.items else return null) else return null;
    return findVarDeclTypeInBody(sname, fn_body);
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
