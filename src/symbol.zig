const ast = @import("./ast.zig");
const misc = @import("./misc.zig");

/// Represents the type of a symbol, which can either be a function or a variable.
pub const SymbolType = enum {
    /// A node symbol.
    Node,
    /// A native function symbol.
    NativeFunction,
    /// An unknown symbol.
    Unknown,
};

/// Represents a symbol in the program, including its type, name, and associated data.
pub const Symbol = struct {
    /// The type of the symbol (e.g., function or variable).
    type: SymbolType,
    /// The name of the symbol.
    name: []const u8,
    /// A pointer to the data associated with the symbol.
    data: *anyopaque,
};

/// Represents a symbol table, which maps symbol names to symbols.
pub const SymbolTable = struct {
    /// The symbols in the table.
    symbols: misc.Vector(Symbol),
};

/// Get a node symbol from a symbol.
pub fn get_node_symbol(s: Symbol) ?*ast.Node {
    if (s.type == SymbolType.Node) {
        return s.data;
    }
    return null;
}
