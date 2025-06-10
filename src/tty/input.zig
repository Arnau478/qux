pub const Input = union(enum) {
    printable: u7,
    escape,
    @"return",
    backspace,
    arrow: Arrow,
    unknown: u8,

    pub const Arrow = enum {
        up,
        down,
        left,
        right,
    };
};
