pub const TokenType = enum {
    Identifier,
    Keyword,
    Operator,
    Symbol,
    Number,
    String,
    Comment,
    NewLine,
};

pub const TokenData = union {
    cval: u8,
    sval: []u8,
    inum: c_int,
    lnum: c_long,
    llnum: c_longlong,
};
