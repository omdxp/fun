const std = @import("std");
const mem = std.mem;
const misc = @import("./misc.zig");
const transpiler = @import("./transpiler.zig");

/// Represents a scope structure used in the transpiler.
pub const Scope = struct {
    /// A vector of entities within the scope.
    entities: misc.Vector(*anyopaque),
    /// A pointer to the parent scope, if any.
    parent: ?*Scope = null,
    /// The allocator to be used for memory allocation operations.
    allocator: mem.Allocator,

    const Self = @This();

    /// Initializes a new instance of `Scope`.
    ///
    /// This function initializes the entity vector with the provided allocator and sets the
    /// peek pointer to the end. It also enables peek decrement.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for memory allocation operations.
    ///
    /// Returns:
    /// - `Self`: A new instance of `Scope`.
    pub fn init(allocator: mem.Allocator) Self {
        var entities = misc.Vector(*anyopaque).init(allocator);
        entities.set_peek_pointer_end();
        entities.flags.peek_decrement = true;
        return Self{
            .entities = misc.Vector(*anyopaque).init(allocator),
            .allocator = allocator,
        };
    }

    /// Starts an iteration over the entities in the scope.
    ///
    /// This function sets the peek pointer to the beginning of the vector. If the peek decrement
    /// flag is enabled, it sets the peek pointer to the end.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    pub fn start_iteration(self: *Self) void {
        self.entities.set_peek_pointer(0);
        if (self.entities.flags.peek_decrement) {
            self.entities.set_peek_pointer_end();
        }
    }

    /// Iterates backward over the entities in the scope.
    ///
    /// This function returns the next entity in the vector, moving backward.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    ///
    /// Returns:
    /// - `?*anyopaque`: The next entity, or `null` if there are no more entities.
    pub fn iterate_back(self: *Self) ?*anyopaque {
        if (self.entities.count == 0) {
            return null;
        }
        return self.entities.peek();
    }

    /// Gets the last entity in the current scope.
    ///
    /// This function returns the last entity in the vector.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    ///
    /// Returns:
    /// - `?*anyopaque`: The last entity in the vector, or `null` if the vector is empty.
    pub fn last_entity_at_scope(self: *Self) ?*anyopaque {
        if (self.entities.count == 0) {
            return null;
        }
        return self.entities.back();
    }

    /// Gets the last entity from the current scope, stopping at a specified scope.
    ///
    /// This function retrieves the last entity from the current scope, stopping at the specified stop scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    /// - `stop_scope`: The scope to stop at when retrieving the last entity.
    ///
    /// Returns:
    /// - `?*anyopaque`: The last entity from the current scope, or `null` if not found.
    pub fn last_entity_from_scope_stop_at(self: *Self, stop_scope: ?*Self) ?*anyopaque {
        if (self == stop_scope) {
            return null;
        }
        const last = self.last_entity_at_scope();
        if (last != null) {
            return last;
        }
        const parent = self.parent;
        if (parent != null) {
            return last_entity_from_scope_stop_at(parent.?, stop_scope);
        }
        return null;
    }

    /// Deinitializes the scope.
    ///
    /// This function deinitializes the entity vector and destroys the parent scope if it exists.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    pub fn deinit(self: Self) void {
        self.entities.deinit();
        if (self.parent != null) {
            self.allocator.destroy(self.parent.?);
        }
    }
};

test "Scope can be initialized and deinitialized" {
    const allocator = std.heap.page_allocator;
    var scope = Scope.init(allocator);
    defer scope.deinit();

    try std.testing.expect(scope.entities.count == 0);
    try std.testing.expect(scope.parent == null);
}

test "Scope can add and retrieve entities" {
    const allocator = std.heap.page_allocator;
    var scope = Scope.init(allocator);
    defer scope.deinit();

    var dummy_entity1: i32 = 42;
    var dummy_entity2: i32 = 100;

    try scope.entities.push(@ptrCast(@alignCast(&dummy_entity1)));
    try scope.entities.push(@ptrCast(@alignCast(&dummy_entity2)));
    var res: *i32 = @ptrCast(@alignCast(scope.last_entity_at_scope().?));
    try std.testing.expect(res == &dummy_entity2);
    scope.start_iteration();
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity1);
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity2);
    try std.testing.expect(scope.iterate_back() == null);
}

test "Scope can handle nested scopes" {
    const allocator = std.heap.page_allocator;
    var root_scope = Scope.init(allocator);
    defer root_scope.deinit();

    var nested_scope = Scope.init(allocator);
    nested_scope.parent = &root_scope;
    // defer nested_scope.deinit(); // TODO: get back here to fix incorrect alignment error

    var dummy_entity1: i32 = 42;
    var dummy_entity2: i32 = 100;

    try root_scope.entities.push(&dummy_entity1);
    try nested_scope.entities.push(&dummy_entity2);

    var res: *i32 = @ptrCast(@alignCast(root_scope.last_entity_at_scope().?));
    try std.testing.expect(res == &dummy_entity1);
    res = @ptrCast(@alignCast(nested_scope.last_entity_at_scope().?));
    try std.testing.expect(res == &dummy_entity2);

    // Test last_entity_from_scope_stop_at
    res = @ptrCast(@alignCast(nested_scope.last_entity_from_scope_stop_at(&root_scope).?));
    try std.testing.expect(res == &dummy_entity2);
    res = @ptrCast(@alignCast(root_scope.last_entity_from_scope_stop_at(null).?));
    try std.testing.expect(res == &dummy_entity1);
}

test "Scope iteration and peek decrement works correctly" {
    const allocator = std.heap.page_allocator;
    var scope = Scope.init(allocator);
    defer scope.deinit();

    var dummy_entity1: i32 = 1;
    var dummy_entity2: i32 = 2;
    var dummy_entity3: i32 = 3;

    try scope.entities.push(&dummy_entity1);
    try scope.entities.push(&dummy_entity2);
    try scope.entities.push(&dummy_entity3);

    // Test forward iteration
    scope.entities.flags.peek_decrement = false;
    scope.start_iteration();
    var res: *i32 = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity1);
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity2);
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity3);
    try std.testing.expect(scope.iterate_back() == null);

    // Test backward iteration
    scope.entities.flags.peek_decrement = true;
    scope.start_iteration();
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity3);
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity2);
    res = @ptrCast(@alignCast(scope.iterate_back().?));
    try std.testing.expect(res == &dummy_entity1);
    try std.testing.expect(scope.iterate_back() == null);
}
