const std = @import("std");
const mem = std.mem;
const misc = @import("./misc.zig");

/// Flags representing various states in the history.
pub const HistoryFlags = packed struct {
    /// Indicates the global scope.
    is_global_scope: bool = false,
    /// Indicates that we are inside a function body.
    inside_function_body: bool = false,
    /// Indicates that we are inside a fit statement.
    in_fit_statement: bool = false,
    /// Indicates that the parenthesis is not part of a function call.
    parenthesis_not_function_call: bool = false,
};

/// Represents the branches in a fit statement.
pub const HistoryFitBranches = struct {
    /// The branches of the fit statement.
    branches: misc.Vector(u8),
    /// Indicates if the fit statement has a default case.
    has_default_case: bool,
};

pub const History = struct {
    flags: HistoryFlags,
    fit: ?struct {
        branch_data: HistoryFitBranches,
    } = null,
    allocator: mem.Allocator,

    const Self = @This();

    /// Initializes a new History instance.
    ///
    /// Parameters:
    /// - `allocator (mem.Allocator)`: The allocator to use for memory allocation.
    /// - `flags (i8)`: The initial flags to set.
    ///
    /// Returns:
    /// - `Self`: The initialized History instance.
    pub fn init(allocator: mem.Allocator, flags: HistoryFlags) Self {
        return Self{
            .flags = flags,
            .allocator = allocator,
        };
    }

    /// Updates the flags of a History instance and creates a new instance.
    ///
    /// This function creates a new History instance with the given flags and copies
    /// the data from the existing History instance. The new instance is returned with
    /// the updated flags.
    ///
    /// Parameters:
    /// - `allocator (mem.Allocator)`: The allocator to use for memory allocation.
    /// - `history (*History)`: The existing History instance to update.
    /// - `flags (i8)`: The new flags to set.
    ///
    /// Returns:
    /// - `Self`: The new History instance with the updated flags.
    pub fn down(allocator: mem.Allocator, history: *History, flags: i8) Self {
        var new_history = init(allocator, flags);
        @memcpy(new_history, history);
        new_history.flags = flags;
        return new_history;
    }

    /// Deinitializes the History instance and releases resources.
    ///
    /// This function deinitializes the History instance, releasing any resources associated
    /// with it. Specifically, it deinitializes the branches in the fit statement data if it exists.
    ///
    /// Parameters:
    /// - `self (Self)`: The History instance to deinitialize.
    pub fn deinit(self: Self) void {
        if (self.fit != null) {
            self.fit.?.branch_data.branches.deinit();
        }
    }
};
