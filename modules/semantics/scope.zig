const std = @import("std");
const mem = std.mem;
const utils = @import("utils");
const codegen = @import("codegen");
const ast = @import("ast");

/// A set of flags that provide metadata for the scope entity.
pub const ScopeEntityFlags = packed struct {
    /// Indicates whether the entity is on the stack.
    on_stack: bool = false,
};

/// Represents an entity within a scope.
pub const ScopeEntity = struct {
    /// A set of flags that provide metadata for the scope entity.
    flags: ScopeEntityFlags,
    /// A pointer to the AST node associated with this entity.
    node: ?*ast.Node,
    /// Entity name.
    name: []const u8,
};

/// Represents a scope structure used in the transpiler.
pub const Scope = struct {
    /// A vector of entities within the scope.
    entities: utils.Vector(*ScopeEntity),
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
        return blk: {
            var entities = utils.Vector(*ScopeEntity).init(allocator);
            entities.set_peek_pointer_end();
            entities.flags.peek_decrement = true;
            break :blk .{
                .entities = entities,
                .allocator = allocator,
            };
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
    /// - `?*ScopeEntity`: The next entity, or `null` if there are no more entities.
    pub fn iterate_back(self: *Self) ?*ScopeEntity {
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
    /// - `?*ScopeEntity`: The last entity in the vector, or `null` if the vector is empty.
    pub fn last_entity_at_scope(self: *Self) ?*ScopeEntity {
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
    /// - `?*ScopeEntity`: The last entity from the current scope, or `null` if not found.
    pub fn last_entity_from_scope_stop_at(self: *Self, stop_scope: ?*Self) ?*ScopeEntity {
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

    /// Gets entity by name.
    ///
    /// This function retrieves an entity by its name from the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    /// - `name`: The name of the entity to retrieve.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The entity with the specified name, or `null` if not found.
    pub fn get_entity_by_name(self: *Self, name: []const u8) ?*ScopeEntity {
        for (self.entities.items()) |entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity;
            }
        }
        return null;
    }

    /// Deinitializes the scope.
    ///
    /// This function deinitializes the entity vector and destroys the parent scope if it exists.
    ///
    /// Parameters:
    /// - `self`: The instance of the scope.
    pub fn deinit(self: *Self) void {
        self.entities.deinit();
        if (self.parent != null) {
            self.parent.?.entities.deinit();
        }
    }
};
