const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    allocation_calls: usize,
    allocated_bytes: usize,
};

pub const TrackingAllocator = struct {
    child: Allocator,
    active_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    window_peak_live_bytes: usize = 0,
    allocation_calls: usize = 0,
    allocated_bytes: usize = 0,

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn beginWindow(self: *TrackingAllocator) Snapshot {
        self.window_peak_live_bytes = self.active_bytes;
        return .{
            .allocation_calls = self.allocation_calls,
            .allocated_bytes = self.allocated_bytes,
        };
    }

    fn recordGrowth(self: *TrackingAllocator, amount: usize) void {
        self.active_bytes += amount;
        self.allocated_bytes += amount;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.active_bytes);
        self.window_peak_live_bytes = @max(self.window_peak_live_bytes, self.active_bytes);
    }

    fn recordShrink(self: *TrackingAllocator, amount: usize) void {
        std.debug.assert(self.active_bytes >= amount);
        self.active_bytes -= amount;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocation_calls += 1;
        self.recordGrowth(len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const remapped = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordResize(memory.len, new_len);
        return remapped;
    }

    fn recordResize(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.recordGrowth(new_len - old_len);
        } else {
            self.recordShrink(old_len - new_len);
        }
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
        self.recordShrink(memory.len);
    }
};

test "tracking allocator records growth and returns to zero live bytes" {
    var tracker = TrackingAllocator{ .child = std.testing.allocator };
    const allocator = tracker.allocator();
    const snapshot = tracker.beginWindow();
    {
        var values: std.ArrayList(u32) = .empty;
        defer values.deinit(allocator);
        try values.appendSlice(allocator, &.{ 1, 2, 3, 4, 5 });
        try std.testing.expect(tracker.allocation_calls > snapshot.allocation_calls);
        try std.testing.expect(tracker.allocated_bytes > snapshot.allocated_bytes);
        try std.testing.expect(tracker.peak_live_bytes >= values.capacity * @sizeOf(u32));
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.active_bytes);
}
