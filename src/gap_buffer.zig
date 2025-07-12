const std = @import("std");

pub fn GapBuffer(T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        raw_buffer: []T,
        gap_start: usize,
        gap_end: usize,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return try @This().initWithCapacity(allocator, 1024);
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, initial_capacity: usize) !@This() {
            return .{
                .allocator = allocator,
                .raw_buffer = try allocator.alloc(T, initial_capacity),
                .gap_start = 0,
                .gap_end = initial_capacity,
            };
        }

        pub fn deinit(gap_buffer: @This()) void {
            gap_buffer.allocator.free(gap_buffer.raw_buffer);
        }

        pub fn getLen(gap_buffer: @This()) usize {
            return gap_buffer.raw_buffer.len - gap_buffer.gapSize();
        }

        pub fn getCapacity(gap_buffer: @This()) usize {
            return gap_buffer.raw_buffer.len;
        }

        fn gapSize(gap_buffer: @This()) usize {
            return gap_buffer.gap_end - gap_buffer.gap_start;
        }

        pub fn moveGapTo(gap_buffer: *@This(), idx: usize) void {
            if (gap_buffer.gap_start == idx) return;

            std.debug.assert(idx <= gap_buffer.getLen());

            if (idx < gap_buffer.gap_start) {
                // Move gap left
                const move_size = gap_buffer.gap_start - idx;
                const src_start = idx;
                const dst_start = gap_buffer.gap_end - move_size;

                std.mem.copyBackwards(T, gap_buffer.raw_buffer[dst_start..gap_buffer.gap_end], gap_buffer.raw_buffer[src_start..gap_buffer.gap_start]);

                gap_buffer.gap_start = idx;
                gap_buffer.gap_end -= move_size;
            } else {
                // Move gap right
                const move_size = idx - gap_buffer.gap_start;
                const src_start = gap_buffer.gap_end;
                const dst_start = gap_buffer.gap_start;

                std.mem.copyForwards(T, gap_buffer.raw_buffer[dst_start .. dst_start + move_size], gap_buffer.raw_buffer[src_start .. src_start + move_size]);

                gap_buffer.gap_start = idx;
                gap_buffer.gap_end += move_size;
            }
        }

        pub fn insert(gap_buffer: *@This(), item: T) !void {
            if (gap_buffer.gapSize() == 0) try gap_buffer.grow();

            gap_buffer.raw_buffer[gap_buffer.gap_start] = item;
            gap_buffer.gap_start += 1;
        }

        pub fn insertSlice(gap_buffer: *@This(), slice: []const T) !void {
            if (gap_buffer.gapSize() < slice.len) try gap_buffer.growToFit(slice.len);

            @memcpy(gap_buffer.raw_buffer[gap_buffer.gap_start .. gap_buffer.gap_start + slice.len], slice);
            gap_buffer.gap_start += slice.len;
        }

        /// Delete one item at the current cursor position (forwards)
        pub fn deleteForwards(gap_buffer: *@This()) void {
            if (gap_buffer.gap_end < gap_buffer.raw_buffer.len) {
                gap_buffer.gap_end += 1;
            }
        }

        /// Delete one item before the current cursor position (backwards, like backspace)
        pub fn deleteBackwards(gap_buffer: *@This()) void {
            if (gap_buffer.gap_start > 0) {
                gap_buffer.gap_start -= 1;
            }
        }

        // TODO: Delete range

        pub fn getAt(gap_buffer: @This(), idx: usize) ?T {
            if (idx >= gap_buffer.getLen()) return null;

            if (idx < gap_buffer.gap_start) {
                return gap_buffer.raw_buffer[idx];
            } else {
                return gap_buffer.raw_buffer[idx + gap_buffer.gapSize()];
            }
        }

        pub fn setAt(gap_buffer: *@This(), idx: usize, value: T) void {
            std.debug.assert(idx < gap_buffer.getLen());

            if (idx < gap_buffer.gap_start) {
                gap_buffer.raw_buffer[idx] = value;
            } else {
                gap_buffer.raw_buffer[idx + gap_buffer.gapSize()] = value;
            }
        }

        fn grow(gap_buffer: *@This()) !void {
            const new_capacity = gap_buffer.raw_buffer.len * 2;
            try gap_buffer.resize(new_capacity);
        }

        fn growToFit(gap_buffer: *@This(), min_additional: usize) !void {
            const current_gap = gap_buffer.gapSize();
            if (current_gap >= min_additional) return;

            const needed_additional = min_additional - current_gap;
            const new_capacity = gap_buffer.raw_buffer.len + needed_additional;
            try gap_buffer.resize(new_capacity);
        }

        // TODO: Try to resize allocation in-place
        fn resize(gap_buffer: *@This(), new_capacity: usize) !void {
            if (new_capacity <= gap_buffer.getCapacity()) return;

            const old_buffer = gap_buffer.raw_buffer;
            const new_buffer = try gap_buffer.allocator.alloc(T, new_capacity);

            if (gap_buffer.gap_start > 0) {
                @memcpy(new_buffer[0..gap_buffer.gap_start], old_buffer[0..gap_buffer.gap_start]);
            }

            if (gap_buffer.gap_end < old_buffer.len) {
                const after_gap_len = old_buffer.len - gap_buffer.gap_end;
                const new_after_gap_start = new_capacity - after_gap_len;
                @memcpy(new_buffer[new_after_gap_start..], old_buffer[gap_buffer.gap_end..]);
                gap_buffer.gap_end = new_after_gap_start;
            } else {
                gap_buffer.gap_end = new_capacity;
            }

            gap_buffer.allocator.free(old_buffer);
            gap_buffer.raw_buffer = new_buffer;
        }

        pub fn print(gap_buffer: @This()) void {
            std.debug.assert(T == u8);

            std.debug.print("GapBuffer: len={}, capacity={}, gap=[{}, {})\n", .{ gap_buffer.getLen(), gap_buffer.getCapacity(), gap_buffer.gap_start, gap_buffer.gap_end });
            std.debug.print("Buffer: [", .{});
            for (gap_buffer.raw_buffer, 0..) |item, i| {
                if (i == gap_buffer.gap_start) std.debug.print(" |", .{});
                if (i >= gap_buffer.gap_start and i < gap_buffer.gap_end) {
                    std.debug.print("_", .{});
                } else {
                    std.debug.print("{c}", .{item});
                }
                if (i == gap_buffer.gap_end - 1) std.debug.print("| ", .{});
            }
            std.debug.print("]\n", .{});
        }
    };
}
