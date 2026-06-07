const std = @import("std");
const token = @import("lexer").token;

pub fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

pub const Allocator = std.mem.Allocator;

pub const Doc = struct {
    uri: []const u8,
    version: i64,
    text: []u8,
    index: ?*Index = null,
    last_diag_ms: i64 = 0,
    /// On-disk mtime (ns) captured the last time this doc's `index` was built
    /// from file contents. Only meaningful for version-0 (FLS-loaded library)
    /// docs; editor-owned buffers (version > 0) are the source of truth and
    /// are never reconciled against disk. 0 = unknown / never stamped.
    index_mtime: i128 = 0,
};

pub const Position = struct { line: i64, character: i64 };
pub const Range = struct { start: Position, end: Position };

pub const Diagnostic = struct {
    range: Range,
    severity: i64,
    message: []const u8,
    code: ?[]const u8 = null,
};

pub const DiagnosticWithUri = struct {
    uri: []u8,
    diag: Diagnostic,
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

pub const CompletionLabelDetails = struct {
    /// Shown dimmed immediately after the label (e.g. the parameter list).
    detail: ?[]const u8 = null,
    /// Shown right-aligned (e.g. the return type or owning module).
    description: ?[]const u8 = null,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?i64 = null,
    detail: ?[]const u8 = null,
    /// Structured label decoration (gopls-style "name(args) returnType").
    labelDetails: ?CompletionLabelDetails = null,
    insertText: ?[]const u8 = null,
    /// 1 = PlainText (default), 2 = Snippet (enables `${1:arg}` placeholders).
    insertTextFormat: ?i64 = null,
    filterText: ?[]const u8 = null,
};

pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const SymbolInformation = struct {
    name: []const u8,
    kind: i64,
    location: Location,
};

pub const DocumentSymbol = struct {
    name: []const u8,
    kind: i64,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = null,
};

pub const ParameterInformation = struct {
    label: []const u8,
};

pub const SignatureInformation = struct {
    label: []const u8,
    parameters: ?[]const ParameterInformation = null,
};

pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: i64 = 0,
    activeParameter: i64 = 0,
};

pub const SemanticTokens = struct {
    data: []const u32,
};

pub const InlayHint = struct {
    position: Position,
    label: []const u8,
    /// 1 = Type, 2 = Parameter.
    kind: ?i64 = null,
    paddingLeft: bool = false,
    paddingRight: bool = false,
};

pub const TokenLiteKind = enum {
    identifier,
    keyword,
    number,
    string,
    boolean,
    comment,
    operator,
    symbol,
};

pub const TokenLite = struct {
    kind: TokenLiteKind,
    text: []const u8,
    range: Range,
};

pub const SymbolKind = enum(i64) {
    file = 1,
    module = 2,
    namespace = 3,
    package = 4,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    constructor = 9,
    enum_ = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    string = 15,
    number = 16,
    boolean = 17,
    array = 18,
    object = 19,
    key = 20,
    null_ = 21,
    enumMember = 22,
    struct_ = 23,
    event = 24,
    operator = 25,
    typeParameter = 26,
};

pub const SymbolLite = struct {
    name: []const u8,
    kind: SymbolKind,
    decl_range: Range,
    selection_range: Range,
    is_public: bool = true,
    // For local symbols: function range that contains it.
    container_fn_range: ?Range = null,
    // For members: owning type name (compound/quirk).
    container_type: ?[]const u8 = null,
    // For fields/properties: declared type name.
    value_type: ?[]const u8 = null,
    // Optional detail shown in completion/hover.
    detail: ?[]const u8 = null,
};

pub const Index = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    tokens: []TokenLite,
    symbols: []SymbolLite,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
