const std = @import("std");
const linux = std.os.linux;
const max_align = @alignOf(std.c.max_align_t);

const Heap = @This();

const Header = extern struct {
    size: usize align(max_align),
    is_free: bool,
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
}

current_brk: usize = 0,
head: ?*Header = null,
tail: ?*Header = null,
mutex: std.atomic.Mutex = .unlocked,
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

fn get_free_block(self: *Heap, size: usize) ?*Header {
    var curr = self.head;
    while (curr) |node| {
        if (node.is_free and node.size >= size)
            return node;
        curr = node.next;
    }
    return null;
}

fn lock(self: *Heap) void {
    while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock(self: *Heap) void {
    self.mutex.unlock();
}

pub fn alloc(self: *Heap, requested: usize) error{OutOfMemory}![*]u8 {
    if (requested > max_size) return error.OutOfMemory;
    const size = std.mem.alignForward(usize, requested, max_align);
    self.lock();
    defer self.unlock();
    const header = self.get_free_block(size) orelse {
        const total_size = @sizeOf(Header) + size;
        const block = try self.sbrk(@intCast(total_size));
        const header: *Header = @ptrCast(@alignCast(block));
        header.*.size = size;
        header.*.is_free = false;
        header.*.next = null;
        if (self.head == null)
            self.head = header;
        if (self.tail) |t|
            t.*.next = header;
        self.tail = header;
        return header.payload();
    };
    header.*.is_free = false;
    return header.payload();
}

pub fn free(self: *Heap, block: [*]u8) void {
    self.lock();
    defer self.unlock();
    const header: *Header = Header.fromPayload(block);

    if (@intFromPtr(block) + header.*.size == self.current_brk) {
        if (self.head == self.tail) {
            self.head = null;
            self.tail = null;
        } else {
            var tmp = self.head;
            while (tmp) |node| {
                if (node.next == self.tail) {
                    node.next = null;
                    self.tail = tmp;
                }
                tmp = node.next;
            }
        }
        const block_size = @as(isize, @intCast(@sizeOf(Header) + header.*.size));
        _ = self.sbrk(-block_size) catch return;
        return;
    }
    header.*.is_free = true;
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
    const size = std.mem.alignForward(usize, requested, max_align);
    self.lock();
    defer self.unlock();

    _ = try self.sbrk(0);
    const padding = std.mem.alignForward(usize, self.current_brk + @sizeOf(Header), alignment) - (self.current_brk + @sizeOf(Header));
    // const header = self.get_free_block(size) orelse {
    const total_size = std.math.add(usize, @sizeOf(Header) + size, padding) catch return error.OutOfMemory;
    const block = try self.sbrk(std.math.cast(isize, total_size) orelse return error.OutOfMemory);
    const header: *Header = @ptrCast(@alignCast(block + padding));
    header.*.size = size;
    header.*.is_free = false;
    header.*.next = null;
    if (self.head == null)
        self.head = header;
    if (self.tail) |t| {
        t.*.size += padding;
        t.*.next = header;
    }
    self.tail = header;
    return header.payload();
    // };
    // header.*.is_free = false;
    // return header.payload();
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
