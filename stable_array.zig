const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const heap = std.heap;
const assert = std.debug.assert;

const AllocError = std.mem.Allocator.Error;

const darwin = struct {
    extern "c" fn madvise(ptr: [*]align(heap.page_size_min) u8, length: usize, advice: c_int) c_int;
};

pub fn StableArray(comptime T: type) type {
    return StableArrayAligned(T, @alignOf(T));
}

pub fn StableArrayAligned(comptime T: type, comptime _alignment: u29) type {
    if (@sizeOf(T) == 0) {
        @compileError("StableArray does not support types of size 0. Use ArrayList instead.");
    }

    return struct {
        const Self = @This();

        pub const Slice = []align(alignment) T;
        pub const VariableSlice = [*]align(alignment) T;

        pub const k_sizeof: usize = if (alignment > @sizeOf(T)) alignment else @sizeOf(T);
        pub const page_size: usize = heap.pageSize();
        pub const alignment = _alignment;

        items: Slice,
        capacity: usize,
        max_virtual_alloc_bytes: usize,

        pub fn getPageSize(self: *Self) usize {
            _ = self;
            return Self.page_size;
        }

        pub fn getAlignment(self: *Self) usize {
            _ = self;
            return Self.alignment;
        }

        pub fn init(max_virtual_alloc_bytes: usize) Self {
            assert(@mod(max_virtual_alloc_bytes, page_size) == 0); // max_virtual_alloc_bytes must be a multiple of page_size
            return Self{
                .items = &[_]T{},
                .capacity = 0,
                .max_virtual_alloc_bytes = max_virtual_alloc_bytes,
            };
        }

        pub fn initCapacity(max_virtual_alloc_bytes: usize, capacity: usize) AllocError!Self {
            var self = Self.init(max_virtual_alloc_bytes);
            try self.ensureTotalCapacity(capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.clearAndFree();
        }

        pub fn insert(self: *Self, n: usize, item: T) AllocError!void {
            try self.ensureUnusedCapacity(1);
            self.items.len += 1;

            mem.copyBackwards(T, self.items[n + 1 .. self.items.len], self.items[n .. self.items.len - 1]);
            self.items[n] = item;
        }

        pub fn insertSlice(self: *Self, i: usize, items: []const T) AllocError!void {
            try self.ensureUnusedCapacity(items.len);
            self.items.len += items.len;

            mem.copyBackwards(T, self.items[i + items.len .. self.items.len], self.items[i .. self.items.len - items.len]);
            @memcpy(self.items[i .. i + items.len], items);
        }

        pub fn replaceRange(self: *Self, start: usize, len: usize, new_items: []const T) AllocError!void {
            const after_range = start + len;
            const range = self.items[start..after_range];

            if (range.len == new_items.len)
                @memcpy(range, new_items)
            else if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];

                @memcpy(range, first);
                try self.insertSlice(after_range, rest);
            } else {
                @memcpy(range, new_items);
                const after_subrange = start + new_items.len;

                for (self.items[after_range..], 0..) |item, i| {
                    self.items[after_subrange..][i] = item;
                }

                self.items.len -= len - new_items.len;
            }
        }

        pub fn append(self: *Self, item: T) AllocError!void {
            const new_item_ptr = try self.addOne();
            new_item_ptr.* = item;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAssumeCapacity();
            new_item_ptr.* = item;
        }

        pub fn appendSlice(self: *Self, items: []const T) AllocError!void {
            try self.ensureUnusedCapacity(items.len);
            self.appendSliceAssumeCapacity(items);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            assert(new_len <= self.capacity);
            self.items.len = new_len;
            @memcpy(self.items[old_len..], items);
        }

        pub fn appendNTimes(self: *Self, value: T, n: usize) AllocError!void {
            const old_len = self.items.len;
            try self.resize(self.items.len + n);
            @memset(self.items[old_len..self.items.len], value);
        }

        pub fn appendNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const new_len = self.items.len + n;
            assert(new_len <= self.capacity);
            @memset(self.items.ptr[self.items.len..new_len], value);
            self.items.len = new_len;
        }

        pub const Writer = if (T != u8)
            @compileError("The Writer interface is only defined for StableArray(u8) " ++
                "but the given type is StableArray(" ++ @typeName(T) ++ ")")
        else
            std.io.Writer(*Self, error{OutOfMemory}, appendWrite);

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        fn appendWrite(self: *Self, m: []const u8) AllocError!usize {
            try self.appendSlice(m);
            return m.len;
        }

        pub fn addOne(self: *Self) AllocError!*T {
            const newlen = self.items.len + 1;
            try self.ensureTotalCapacity(newlen);
            return self.addOneAssumeCapacity();
        }

        pub fn addOneAssumeCapacity(self: *Self) *T {
            assert(self.items.len < self.capacity);

            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        pub fn addManyAsArray(self: *Self, comptime n: usize) AllocError!*[n]T {
            const prev_len = self.items.len;
            try self.resize(self.items.len + n);
            return self.items[prev_len..][0..n];
        }

        pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.capacity);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        pub fn orderedRemove(self: *Self, i: usize) T {
            const newlen = self.items.len - 1;
            if (newlen == i) return self.pop();

            const old_item = self.items[i];
            for (self.items[i..newlen], 0..) |*b, j| b.* = self.items[i + 1 + j];
            self.items[newlen] = undefined;
            self.items.len = newlen;
            return old_item;
        }

        pub fn swapRemove(self: *Self, i: usize) T {
            if (self.items.len - 1 == i) return self.pop();

            const old_item = self.items[i];
            self.items[i] = self.pop();
            return old_item;
        }

        pub fn resize(self: *Self, new_len: usize) AllocError!void {
            try self.ensureTotalCapacity(new_len);
            self.items.len = new_len;
        }

        pub fn shrinkAndFree(self: *Self, new_len: usize) void {
            assert(new_len <= self.items.len);

            const new_capacity_bytes = calcBytesUsedForCapacity(new_len);
            const current_capacity_bytes: usize = calcBytesUsedForCapacity(self.capacity);

            if (new_capacity_bytes < current_capacity_bytes) {
                const bytes_to_free: usize = current_capacity_bytes - new_capacity_bytes;

                if (builtin.os.tag == .windows) {
                    const w = os.windows;
                    const addr: usize = @intFromPtr(self.items.ptr) + new_capacity_bytes;
                    w.VirtualFree(@as(w.PVOID, @ptrFromInt(addr)), bytes_to_free, w.MEM_DECOMMIT);
                } else {
                    const base_addr: usize = @intFromPtr(self.items.ptr);
                    const offset_addr: usize = base_addr + new_capacity_bytes;
                    const addr: [*]align(heap.page_size_min) u8 = @ptrFromInt(offset_addr);
                    if (comptime builtin.os.tag.isDarwin()) {
                        const MADV_DONTNEED = 4;
                        const err: c_int = darwin.madvise(addr, bytes_to_free, MADV_DONTNEED);
                        switch (@as(posix.E, @enumFromInt(err))) {
                            posix.E.INVAL => unreachable,
                            posix.E.NOMEM => unreachable,
                            else => {},
                        }
                    } else {
                        posix.madvise(addr, bytes_to_free, std.c.MADV.DONTNEED) catch unreachable;
                    }
                }

                self.capacity = new_capacity_bytes / k_sizeof;
            }

            self.items.len = new_len;
        }

        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.items.len);
            self.items.len = new_len;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
        }

        pub fn clearAndFree(self: *Self) void {
            if (self.capacity > 0) {
                if (builtin.os.tag == .windows) {
                    const w = os.windows;
                    w.VirtualFree(@as(*anyopaque, @ptrCast(self.items.ptr)), 0, w.MEM_RELEASE);
                } else {
                    var slice: []align(heap.page_size_min) const u8 = undefined;
                    slice.ptr = @alignCast(@as([*]u8, @ptrCast(self.items.ptr)));
                    slice.len = self.max_virtual_alloc_bytes;
                    posix.munmap(slice);
                }
            }

            self.capacity = 0;
            self.items = &[_]T{};
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) AllocError!void {
            const new_capacity_bytes = calcBytesUsedForCapacity(new_capacity);
            const current_capacity_bytes: usize = calcBytesUsedForCapacity(self.capacity);

            if (current_capacity_bytes < new_capacity_bytes) {
                if (self.capacity == 0) {
                    if (builtin.os.tag == .windows) {
                        const w = os.windows;
                        const addr: w.PVOID = w.VirtualAlloc(null, self.max_virtual_alloc_bytes, w.MEM_RESERVE, w.PAGE_READWRITE) catch return AllocError.OutOfMemory;
                        self.items.ptr = @alignCast(@ptrCast(addr));
                        self.items.len = 0;
                    } else {
                        const prot: u32 = std.c.PROT.NONE;
                        const map: std.c.MAP = .{
                            .ANONYMOUS = true,
                            .TYPE = .PRIVATE,
                        };
                        const fd: posix.fd_t = -1;
                        const offset: usize = 0;
                        const slice = posix.mmap(null, self.max_virtual_alloc_bytes, prot, map, fd, offset) catch return AllocError.OutOfMemory;
                        self.items.ptr = @alignCast(@ptrCast(slice.ptr));
                        self.items.len = 0;
                    }
                } else if (current_capacity_bytes == self.max_virtual_alloc_bytes) {
                    // If you hit this, you likely either didn't reserve enough space up-front, or have a leak that is allocating too many elements
                    return AllocError.OutOfMemory;
                }

                if (builtin.os.tag == .windows) {
                    const w = std.os.windows;
                    _ = w.VirtualAlloc(@as(w.PVOID, @ptrCast(self.items.ptr)), new_capacity_bytes, w.MEM_COMMIT, w.PAGE_READWRITE) catch return AllocError.OutOfMemory;
                } else {
                    const resize_capacity = new_capacity_bytes - current_capacity_bytes;
                    const region_begin: [*]u8 = @ptrCast(self.items.ptr);
                    const remap_region_begin: [*]u8 = region_begin + current_capacity_bytes;

                    const prot: u32 = std.c.PROT.READ | std.c.PROT.WRITE;
                    const map: std.c.MAP = .{
                        .ANONYMOUS = true,
                        .TYPE = .PRIVATE,
                        .FIXED = true,
                    };
                    const fd: posix.fd_t = -1;
                    const offset: usize = 0;

                    _ = posix.mmap(@alignCast(remap_region_begin), resize_capacity, prot, map, fd, offset) catch return AllocError.OutOfMemory;
                }
            }

            self.capacity = new_capacity;
        }

        pub fn ensureUnusedCapacity(self: *Self, additional_count: usize) AllocError!void {
            return self.ensureTotalCapacity(self.items.len + additional_count);
        }

        pub fn expandToCapacity(self: *Self) void {
            self.items.len = self.capacity;
        }

        pub fn pop(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.pop();
        }

        pub fn allocatedSlice(self: Self) Slice {
            return self.items.ptr[0..self.capacity];
        }

        // Make sure to update self.items.len if you indend for any writes to this
        // to modify the length of the array.
        pub fn unusedCapacitySlice(self: Self) Slice {
            return self.allocatedSlice()[self.items.len..];
        }

        pub fn calcTotalUsedBytes(self: Self) usize {
            return calcBytesUsedForCapacity(self.capacity);
        }

        fn calcBytesUsedForCapacity(capacity: usize) usize {
            return mem.alignForward(usize, k_sizeof * capacity, page_size);
        }
    };
}

const TEST_VIRTUAL_ALLOC_SIZE = 1024 * 1024 * 2; // 2 MB

test "init" {
    var a = StableArray(u8).init(TEST_VIRTUAL_ALLOC_SIZE);
    assert(a.items.len == 0);
    assert(a.capacity == 0);
    assert(a.max_virtual_alloc_bytes == TEST_VIRTUAL_ALLOC_SIZE);
    a.deinit();

    var b = StableArrayAligned(u8, 16).init(TEST_VIRTUAL_ALLOC_SIZE);
    assert(b.getAlignment() == 16);
    assert(b.items.len == 0);
    assert(b.capacity == 0);
    assert(b.max_virtual_alloc_bytes == TEST_VIRTUAL_ALLOC_SIZE);
    b.deinit();

    assert(a.getPageSize() == b.getPageSize());
}

test "append" {
    var a = StableArray(u8).init(TEST_VIRTUAL_ALLOC_SIZE);
    try a.appendSlice(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    assert(a.calcTotalUsedBytes() == a.getPageSize());
    for (a.items, 0..) |v, i| {
        assert(v == i);
    }
    a.deinit();

    var b = StableArrayAligned(u8, heap.pageSize()).init(TEST_VIRTUAL_ALLOC_SIZE);
    try b.appendSlice(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    assert(b.calcTotalUsedBytes() == a.getPageSize() * 10);
    for (b.items, 0..) |v, i| {
        assert(v == i);
    }
    b.deinit();
}

test "shrinkAndFree" {
    const page_size = heap.pageSize();

    var a = StableArray(u8).init(TEST_VIRTUAL_ALLOC_SIZE);
    try a.appendSlice(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    a.shrinkAndFree(5);
    assert(a.calcTotalUsedBytes() == page_size); // still using only a page
    assert(a.items.len == 5);
    for (a.items, 0..) |v, i| {
        assert(v == i);
    }
    a.deinit();

    var b = StableArrayAligned(u8, heap.pageSize()).init(TEST_VIRTUAL_ALLOC_SIZE);
    try b.appendSlice(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    b.shrinkAndFree(5);
    assert(b.calcTotalUsedBytes() == page_size * 5); // alignment of each item is 1 page
    assert(b.items.len == 5);
    for (b.items, 0..) |v, i| {
        assert(v == i);
    }
    b.deinit();

    var c = StableArrayAligned(u8, page_size / 2).init(TEST_VIRTUAL_ALLOC_SIZE);
    assert(c.getAlignment() == page_size / 2);
    try c.appendSlice(&[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    c.shrinkAndFree(5);
    assert(c.calcTotalUsedBytes() == page_size * 3);
    assert(c.capacity == 6);
    assert(c.items.len == 5);
    for (c.items, 0..) |v, i| {
        assert(v == i);
    }
    c.deinit();
}

test "resize" {
    const max: usize = 1024 * 1024 * 1;
    var a = StableArray(u8).init(max);
    defer a.deinit();

    var size: usize = 512;
    while (size <= max) {
        try a.resize(size);
        size *= 2;
    }
}

test "out of memory" {
    var a = StableArrayAligned(u8, heap.pageSize()).init(TEST_VIRTUAL_ALLOC_SIZE);
    defer a.deinit();

    const max_capacity: usize = TEST_VIRTUAL_ALLOC_SIZE / a.getPageSize();
    try a.appendNTimes(0xFF, max_capacity);
    for (a.items) |v| {
        assert(v == 0xFF);
    }
    assert(a.max_virtual_alloc_bytes == a.calcTotalUsedBytes());
    assert(a.capacity == max_capacity);
    assert(a.items.len == max_capacity);

    var didCatchError: bool = false;
    a.append(0) catch |err| {
        didCatchError = true;
        assert(err == error.OutOfMemory);
    };
    assert(didCatchError == true);
}

test "huge max size" {
    const KB = 1024;
    const MB = KB * 1024;
    const GB = MB * 1024;

    const MAX_MEMORY_32 = GB * 1;
    const MAX_MEMORY_64 = GB * 128;
    const MAX_MEMORY = if (@sizeOf(usize) < @sizeOf(u64)) MAX_MEMORY_32 else MAX_MEMORY_64;

    var a = StableArray(u8).init(MAX_MEMORY);
    defer a.deinit();

    try a.resize(MB * 4);
    try a.resize(MB * 8);
    try a.resize(MB * 16);
    a.items[MB * 16 - 1] = 0xFF;
}

test "growing retains values" {
    var a = StableArray(u8).init(TEST_VIRTUAL_ALLOC_SIZE);
    defer a.deinit();

    try a.resize(a.getPageSize());
    a.items[0] = 0xFF;
    try a.resize(a.getPageSize() * 2);
    assert(a.items[0] == 0xFF);
}
