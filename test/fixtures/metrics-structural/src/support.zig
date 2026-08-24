pub const Mode = enum { fast, safe };
pub const Failure = error{Unavailable};
pub const Namespace = struct {
    pub const Nested = struct {};
};

pub fn choose(comptime T: type, value: T) T {
    return value;
}
