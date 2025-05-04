const std = @import("std");
const semantics = @import("semantics");
const Scope = semantics.scope.Scope;
const ScopeEntity = semantics.scope.ScopeEntity;
const ScopeEntityFlags = semantics.scope.ScopeEntityFlags;

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

    var entity1 = ScopeEntity{ .flags = ScopeEntityFlags{ .on_stack = false }, .node = null, .name = "entity1" };
    var entity2 = ScopeEntity{ .flags = ScopeEntityFlags{ .on_stack = false }, .node = null, .name = "entity2" };

    try scope.entities.push(&entity1);
    try scope.entities.push(&entity2);

    try std.testing.expect(scope.entities.items()[0] == &entity1);
    try std.testing.expect(scope.entities.items()[1] == &entity2);
}

test "Scope iteration works correctly" {
    const allocator = std.heap.page_allocator;
    var scope = Scope.init(allocator);
    defer scope.deinit();

    var entity1 = ScopeEntity{ .flags = ScopeEntityFlags{ .on_stack = false }, .node = null, .name = "entity1" };
    var entity2 = ScopeEntity{ .flags = ScopeEntityFlags{ .on_stack = false }, .node = null, .name = "entity2" };
    var entity3 = ScopeEntity{ .flags = ScopeEntityFlags{ .on_stack = false }, .node = null, .name = "entity3" };

    try scope.entities.push(&entity1);
    try scope.entities.push(&entity2);
    try scope.entities.push(&entity3);

    scope.start_iteration();

    try std.testing.expect(scope.iterate_back().? == &entity3);
    try std.testing.expect(scope.iterate_back().? == &entity2);
    try std.testing.expect(scope.iterate_back().? == &entity1);
    try std.testing.expect(scope.iterate_back() == null);
}
