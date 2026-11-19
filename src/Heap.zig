// Size classes for small blocks:
//   linear classes:  16, 32, 48, ..., 1024          (indices 0 .. linear_class_count-1)
//   pow2 classes:    2048, 4096, ..., small_max     (indices linear_class_count .. class_count-1)
// Anything bigger than `small_max` is mmap'ed directly.

// Chosen values (TESTS ARE HARDCODED FOR THOSE VALUES, UPDATE THEM)
const class_step: usize = 16;
const linear_class_count: usize = 64;
const pow2_class_count: usize = 8;

// Derived values:
const linear_max: usize = class_step * linear_class_count; // 1024
const class_count: usize = linear_class_count + pow2_class_count; // 72
const small_max: usize = linear_max << pow2_class_count; // 262144

// The first pow2 class (linear_max * 2) must land on index `linear_class_count`.
const pow2_class_offset: usize = linear_class_count - (std.math.log2_int_ceil(usize, linear_max) + 1); // 53

const std = @import("std");
const linux = std.os.linux;
const max_align = @alignOf(std.c.max_align_t);

const Heap = @This();

const Header = extern struct {
    size: usize align(max_align),
    next: ?*Header,
    pub fn payload(self: *Header) [*]u8 {
        return @ptrCast(@as([*]Header, @ptrCast(self)) + 1);
    }
    pub fn fromPayload(block: [*]u8) *Header {
        return &(@as([*]Header, @ptrCast(@alignCast(block))) - 1)[0];
    }
};

comptime {
    if (@sizeOf(Header) % max_align != 0) {
        @compileError(std.fmt.comptimePrint("Header size must be a multiple of {d}", .{max_align}));
    } // quite redundant of check but wouldn't hurt
    if (@alignOf(Header) != max_align) {
        @compileError(std.fmt.comptimePrint("Header alignment must be {d}", .{max_align}));
    }
    if (class_step % max_align != 0) {
        @compileError(std.fmt.comptimePrint("Minimall alignment step heap is not aligned with {d}", .{max_align}));
    }
}

current_brk: usize = 0,
mutex: std.atomic.Mutex = .unlocked,

free_blocks: [class_count]?*Header = @splat(null),

fn getId(_: *Heap, size: usize) ?usize {
    if (size > small_max) {
        return null;
    } else if (size <= linear_max) {
        if (size == 0) return 0;
        return (size + class_step - 1) / class_step - 1;
    } else {
        return std.math.log2_int_ceil(usize, size) + pow2_class_offset;
    }
}

fn classSize(_: *Heap, id: usize) usize {
    if (id < linear_class_count) {
        return id * class_step + class_step;
    } else {
        return std.math.shl(usize, 1, id - pow2_class_offset);
    }
}

const max_size: usize = std.math.maxInt(isize) - @sizeOf(Header) - (max_align - 1);

fn sbrk(self: *Heap, increment: isize) error{OutOfMemory}![*]u8 {
    if (self.current_brk == 0) {
        self.current_brk = linux.syscall1(.brk, 0);
    }
    const old = self.current_brk;
    if (increment == 0) return @ptrFromInt(old);

    const new = old +% @as(usize, @bitCast(increment));
    const result = linux.syscall1(.brk, new);
    if (result != new) return error.OutOfMemory;
    self.current_brk = result;
    return @ptrFromInt(old);
}

fn getFreeBlock(self: *Heap, size: usize) ?*Header {
    const id = self.getId(size) orelse return null;
    const node: *Header = self.free_blocks[id] orelse return null;
    self.free_blocks[id] = node.next;
    node.next = null;
    return node;
}

fn lock(self: *Heap) void {
    while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock(self: *Heap) void {
    self.mutex.unlock();
}

pub fn alloc(self: *Heap, requested: usize) error{OutOfMemory}![*]u8 {
    if (requested > max_size) return error.OutOfMemory;
    if (requested <= small_max) {
        self.lock();
        defer self.unlock();
        const header = self.getFreeBlock(requested) orelse {
            const header = try self.allocSmall(requested);
            return header.payload();
        };
        return header.payload();
    } else {
        const header = try allocBig(requested);
        return header.payload();
    }
}

fn allocSmall(self: *Heap, requested: usize) error{OutOfMemory}!*Header {
    const size = self.classSize(self.getId(requested).?);
    const block = try self.sbrk(@intCast(size + @sizeOf(Header)));
    const header: *Header = @ptrCast(@alignCast(block));
    header.size = size;
    return header;
}

fn freeSmall(self: *Heap, header: *Header, size: usize) void {
    self.lock();
    defer self.unlock();
    const id = self.getId(size).?;
    const node = self.free_blocks[id];
    self.free_blocks[id] = header;
    header.*.next = node;
}

// Large blocks get one extra page in front; the header sits at the end of that page,
// so the payload always starts on a page boundary:
//
//   | ...unused... | Header | payload ............ |
//   ^ mapping start         ^ page boundary
fn allocBig(requested: usize) error{OutOfMemory}!*Header {
    const page = std.heap.pageSize();
    const len = page + std.mem.alignForward(usize, requested, page);
    const block = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return error.OutOfMemory;
    const header: *Header = @ptrCast(@alignCast(block.ptr + page - @sizeOf(Header)));
    header.size = block.len - page;
    return header;
}

fn freeBig(header: *Header) void {
    const page = std.heap.pageSize();
    const start = @intFromPtr(header) + @sizeOf(Header) - page;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    std.posix.munmap(base[0 .. header.size + page]);
}

pub fn free(self: *Heap, block: [*]u8) void {
    const header: *Header = Header.fromPayload(block);
    const size = header.size;
    if (size <= small_max) {
        self.freeSmall(header, size);
    } else {
        freeBig(header);
    }
}

pub fn calloc(self: *Heap, num: usize, nsize: usize) error{OutOfMemory}![*]u8 {
    const size = std.math.mul(usize, num, nsize) catch return error.OutOfMemory;
    const block = try self.alloc(size);
    @memset(block[0..size], 0);
    return block;
}

pub fn realloc(self: *Heap, block: [*]u8, size: usize) error{OutOfMemory}![*]u8 {
    const header: *Header = Header.fromPayload(block);
    if (header.*.size >= size) return block;
    const ret = try self.alloc(size);
    @memcpy(ret[0..header.*.size], block[0..header.*.size]);
    self.free(block);
    return ret;
}

pub fn allocAligned(self: *Heap, alignment: usize, requested: usize) error{OutOfMemory}![*]u8 {
    if (requested > max_size) return error.OutOfMemory;
    if (alignment <= max_align) return self.alloc(requested);
    if (alignment >= (1 << 31)) return error.OutOfMemory;
    if (requested <= small_max) {
        const size = self.classSize(self.getId(requested).?);
        self.lock();
        defer self.unlock();

        _ = try self.sbrk(0);
        const padding = std.mem.alignForward(usize, self.current_brk + @sizeOf(Header), alignment) - (self.current_brk + @sizeOf(Header));
        const total_size = std.math.add(usize, @sizeOf(Header) + size, padding) catch return error.OutOfMemory;
        const block = try self.sbrk(std.math.cast(isize, total_size) orelse return error.OutOfMemory);
        const header: *Header = @ptrCast(@alignCast(block + padding));
        header.*.size = size;
        header.*.next = null;
        return header.payload();
    } else {
        // mmap'ed payloads start on a page boundary, which covers any alignment up to a page.
        if (alignment > std.heap.pageSize()) return error.OutOfMemory;
        return (try allocBig(requested)).payload();
    }
}

pub fn usableSize(_: *Heap, block: [*]u8) usize {
    return Header.fromPayload(block).*.size;
}
// TESTS

test "header <-> payload round trip" {
    var h: Header = undefined;
    const p = h.payload();
    try std.testing.expectEqual(&h, Header.fromPayload(p));
    try std.testing.expectEqual(@intFromPtr(&h) + @sizeOf(Header), @intFromPtr(p));
    try std.testing.expectEqual(0, @intFromPtr(p) % max_align);
}

test "alignment" {
    var heap: Heap = .{};
    for ([_]usize{ 0, 1, 15, 17, 100 }) |size| {
        const ptr = try heap.alloc(size);
        try std.testing.expectEqual(0, @intFromPtr(ptr) % max_align);
    }
}

test "overlap" {
    var heap: Heap = .{};

    const size: usize = 10;
    const val1 = 10;
    const val2 = 20;

    const buffer1 = try heap.alloc(size);
    @memset(buffer1[0..size], val1);

    const buffer2 = try heap.alloc(size);
    @memset(buffer2[0..size], val2);
    try std.testing.expect(std.mem.allEqual(u8, buffer1[0..size], val1));
    try std.testing.expect(std.mem.allEqual(u8, buffer2[0..size], val2));
}

test "reuse after free" {
    var heap: Heap = .{};

    const size = 10;
    const buffer1 = try heap.alloc(size);
    const buffer2 = try heap.alloc(size);
    heap.free(buffer1);
    const buffer3 = try heap.alloc(size);
    _ = buffer2;
    try std.testing.expectEqual(buffer1, buffer3);
}

test "realloc keeps the data" {
    var heap: Heap = .{};

    const size = 10;
    const val = 99;
    var buffer = try heap.alloc(size);
    @memset(buffer[0..size], val);
    buffer = try heap.realloc(buffer, size * 2);
    try std.testing.expect(std.mem.allEqual(u8, buffer[0..size], val));
}

test "size too big" {
    var heap: Heap = .{};
    try std.testing.expectError(error.OutOfMemory, heap.alloc(std.math.maxInt(usize)));
}

test "set alignment" {
    var heap: Heap = .{};
    for ([_]usize{ 0, 1, 15, 17, 100 }, [_]usize{ 32, 64, 128, 256, 4096 }) |size, allign| {
        const ptr = try heap.allocAligned(allign, size);
        try std.testing.expectEqual(0, @intFromPtr(ptr) % allign);
    }
}

test "size -> id -> size" {
    var heap: Heap = .{};
    const input_sizes = [_]usize{ 0, 1, 17, 39, linear_max - 1 };
    const ids = [_]usize{ 0, 0, 1, 2, linear_class_count - 1 };
    const output_sizes = [_]usize{ 16, 16, 32, 48, linear_max };

    for (input_sizes, 0..) |size, i| {
        const id = ids[i];
        try std.testing.expectEqual(heap.getId(size).?, id);
        try std.testing.expectEqual(heap.classSize(id), output_sizes[i]);
    }

    try std.testing.expectEqual(null, heap.getId(small_max + 1));
}
