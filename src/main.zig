const std = @import("std");
const linux = std.os.linux;
const Heap = @import("Heap.zig");

var heap: Heap = .{};

export fn malloc(requested: usize) ?*anyopaque {
    return heap.alloc(requested) catch null;
}

export fn free(ptr: ?*anyopaque) void {
    const block = ptr orelse return;
    heap.free(@ptrCast(block));
}

export fn calloc(num: usize, nsize: usize) ?*anyopaque {
    return heap.calloc(num, nsize) catch null;
}

export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const block = ptr orelse return malloc(size);
    return heap.realloc(@ptrCast(block), size) catch null;
}

export fn reallocarray(ptr: ?*anyopaque, n: usize, size: usize) ?*anyopaque {
    const total_size = std.math.mul(usize, n, size) catch return null;
    return realloc(ptr, total_size);
}

export fn posix_memalign(res: *?*anyopaque, alignd: usize, size: usize) c_int {
    if (alignd < @sizeOf(*anyopaque)) return @intFromEnum(std.posix.E.INVAL);
    if (!std.mem.isValidAlign(alignd)) return @intFromEnum(std.posix.E.INVAL);
    const mem = heap.allocAligned(alignd, size) catch |err| return switch (err) {
        error.OutOfMemory => @intFromEnum(std.posix.E.NOMEM),
    };
    res.* = mem;
    return 0;
}

export fn aligned_alloc(alignd: usize, size: usize) ?*anyopaque {
    if (!std.mem.isValidAlign(alignd)) return null;
    return heap.allocAligned(alignd, size) catch null;
}
export fn memalign(alignd: usize, size: usize) ?*anyopaque {
    if (!std.mem.isValidAlign(alignd)) return null;
    return heap.allocAligned(alignd, size) catch null;
}
export fn malloc_usable_size(ptr: ?*anyopaque) usize {
    const block = ptr orelse return 0;
    return heap.usableSize(@ptrCast(block));
}

export fn valloc(size: usize) ?*anyopaque {
    const page = std.heap.pageSize();
    return aligned_alloc(page, size);
}
export fn pvalloc(size: usize) ?*anyopaque {
    const page = std.heap.pageSize();
    if (size >= (1 << 31)) return null;
    const total_size = std.mem.alignForward(usize, size, page);
    return aligned_alloc(page, total_size);
}
// TESTS
test {
    _ = @import("Heap.zig");
}
