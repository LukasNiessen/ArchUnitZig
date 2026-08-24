pub const Mode = enum { fast, safe };
pub const Failure = error{Unavailable};

pub fn choose(comptime T: type, value: T) T {
    return value;
}
