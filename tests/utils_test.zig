const std = @import("std");
const utils = @import("utils");
const Vector = utils.Vector;

test "Vector can be initialized and deinitialized" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try std.testing.expectEqual(0, vec.count);
    try std.testing.expectEqual(0, vec.pindex);
    try std.testing.expect(vec.is_empty());
}

test "Vector can push and retrieve elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try std.testing.expectEqual(1, vec.count);
    try std.testing.expectEqual(42, vec.back().?);
    try std.testing.expectEqual(42, vec.at(0).?);

    try vec.push(100);
    try std.testing.expectEqual(2, vec.count);
    try std.testing.expectEqual(100, vec.back().?);
    try std.testing.expectEqual(100, vec.at(1).?);
}

test "Vector can push slice and retrieve elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push_slice(&[_]u8{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(5, vec.count);
    try std.testing.expectEqual(1, vec.at(0).?);
    try std.testing.expectEqual(5, vec.at(4).?);
}

test "Vector can peek and pop elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    try std.testing.expectEqual(42, vec.peek().?);
    try std.testing.expectEqual(100, vec.peek().?);

    vec.pop_last_peek();
    try std.testing.expectEqual(100, vec.peek().?);

    vec.pop();
    try std.testing.expectEqual(1, vec.count);
    try std.testing.expectEqual(42, vec.back().?);

    vec.peek_pop();
    try std.testing.expectEqual(0, vec.count);
    try std.testing.expect(vec.is_empty());
}

test "Vector can clear elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);
    try std.testing.expectEqual(2, vec.count);

    vec.clear();
    try std.testing.expectEqual(0, vec.count);
    try std.testing.expect(vec.is_empty());
}

test "Vector can set peek pointer" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    vec.set_peek_pointer(1);
    try std.testing.expectEqual(100, vec.peek().?);

    vec.set_peek_pointer_end();
    try std.testing.expectEqual(100, vec.peek().?);
    try std.testing.expectEqual(null, vec.peek());
}

test "Vector can push at specific index" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);
    try vec.push_at(1, 50);

    try std.testing.expectEqual(3, vec.count);
    try std.testing.expectEqual(42, vec.at(0).?);
    try std.testing.expectEqual(50, vec.at(1).?);
    try std.testing.expectEqual(100, vec.at(2).?);
}

test "Vector can retrieve items as slice" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    const items = vec.items();
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqual(42, items[0]);
    try std.testing.expectEqual(100, items[1]);
}

test "Vector can peek at element without incrementing the peek index" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    const first_peek = vec.peek_no_increment();
    try std.testing.expectEqual(42, first_peek.?);
    try std.testing.expectEqual(42, vec.peek_no_increment().?);

    // Ensure that the peek index has not been incremented
    try std.testing.expectEqual(42, vec.peek().?); // This should still return 42 and increment the peek index

    const second_peek = vec.peek_no_increment();
    try std.testing.expectEqual(100, second_peek.?);
    try std.testing.expectEqual(100, vec.peek_no_increment().?);

    // Ensure that the peek index has only incremented by 1
    try std.testing.expectEqual(100, vec.peek().?); // This should now return 100 and increment the peek index
}

test "Vector can peek and decrement index when peek_decrement is true" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    vec.flags.peek_decrement = true;
    vec.set_peek_pointer_end();

    // Peek and expect decrement
    try std.testing.expectEqual(100, vec.peek().?);
    try std.testing.expectEqual(42, vec.peek().?); // After decrement, it should peek 42 again

    // Reset flag and check normal increment behavior
    vec.flags.peek_decrement = false;
    try std.testing.expectEqual(null, vec.peek()); // After increment, it should be out of bounds
}

test "Vector can push and retrieve elements with peek_decrement flag" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    vec.flags.peek_decrement = true;
    vec.set_peek_pointer_end();

    // Peek without decrement
    try std.testing.expectEqual(100, vec.peek_no_increment().?);

    // Peek and decrement
    try std.testing.expectEqual(100, vec.peek().?);
    try std.testing.expectEqual(42, vec.peek().?); // After decrement, it should peek 42 again

    // Pop the last peeked element
    vec.pop();
    try std.testing.expectEqual(1, vec.count);
    try std.testing.expectEqual(42, vec.back().?);
}

test "Vector peek pointer increment and decrement with peek_decrement flag" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);
    try vec.push(4);

    // Test increment behavior
    try std.testing.expectEqual(1, vec.peek().?);
    try std.testing.expectEqual(2, vec.peek().?);
    try std.testing.expectEqual(3, vec.peek().?);
    try std.testing.expectEqual(4, vec.peek().?);

    vec.set_peek_pointer(3); // Set the pointer to the end

    vec.flags.peek_decrement = true;
    vec.set_peek_pointer_end();

    // Test decrement behavior
    try std.testing.expectEqual(4, vec.peek().?);
    try std.testing.expectEqual(3, vec.peek().?);
    try std.testing.expectEqual(2, vec.peek().?);
    try std.testing.expectEqual(1, vec.peek().?);
}

test "misc keyword and operator helpers" {
    try std.testing.expect(utils.keyword_is_datatype("num"));
    try std.testing.expect(utils.keyword_is_datatype("str"));
    try std.testing.expect(!utils.keyword_is_datatype("void"));

    try std.testing.expect(utils.is_keyword("fun"));
    try std.testing.expect(utils.is_keyword("if"));
    try std.testing.expect(!utils.is_keyword("nope"));

    try std.testing.expect(utils.is_boolean_keyword("true"));
    try std.testing.expect(utils.is_boolean_keyword("false"));
    try std.testing.expect(!utils.is_boolean_keyword("True"));

    try std.testing.expect(utils.op_valid("=="));
    try std.testing.expect(utils.op_valid("!="));
    try std.testing.expect(utils.op_valid(">="));
    try std.testing.expect(utils.op_valid("<="));
    try std.testing.expect(utils.op_valid(".."));
    try std.testing.expect(utils.op_valid("..."));
    try std.testing.expect(utils.op_valid("->"));
    try std.testing.expect(!utils.op_valid("?"));

    try std.testing.expect(utils.is_unary_operator("!"));
    try std.testing.expect(utils.is_unary_operator("++"));
    try std.testing.expect(!utils.is_unary_operator("=="));

    try std.testing.expect(utils.is_left_operanded_unary_operator("++"));
    try std.testing.expect(!utils.is_left_operanded_unary_operator("!"));
}

test "misc escape and datatype helpers" {
    try std.testing.expectEqual(@as(u8, '\n'), utils.get_escape_char('n'));
    try std.testing.expectEqual(@as(u8, '\\'), utils.get_escape_char('\\'));
    try std.testing.expectEqual(@as(u8, 0), utils.get_escape_char('x'));

    try std.testing.expectEqual(@import("semantics").dtype.DataTypeType.Num, utils.get_datatype_type("num"));
    try std.testing.expectEqual(@import("semantics").dtype.DataTypeType.Unknown, utils.get_datatype_type("wat"));
}

test "print_node writes something" {
    const ast = @import("ast");

    const num_node = ast.Node{ .type = .Number };
    const id_node = ast.Node{ .type = .Identifier };
    const expr_node = ast.Node{
        .type = .Expression,
        .node_variant = .{ .exp = .{ .op = "==", .left = @constCast(&id_node), .right = @constCast(&num_node) } },
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try utils.print_node(expr_node, fbs.writer(), 0);
    const out = fbs.getWritten();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "Node Type") != null);
}
