const std = @import("std");

pub const IOBufferPool = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    free_list: ?*IOBuffer,
    free_count: usize,
    max_free: usize,
    in_use: usize,

    pub const Options = struct {
        block_size: usize = 4096,
        max_free: usize = 256,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) IOBufferPool {
        return IOBufferPool{
            .allocator = allocator,
            .block_size = options.block_size,
            .free_list = null,
            .free_count = 0,
            .max_free = options.max_free,
            .in_use = 0,
        };
    }

    pub fn deinit(self: *IOBufferPool) void {
        var cur = self.free_list;
        while (cur) |node| {
            cur = node.next_free;
            self.allocator.free(node.data[0..node.capacity]);
            self.allocator.destroy(node);
        }
        self.free_list = null;
        self.free_count = 0;
    }

    pub fn acquire(self: *IOBufferPool) !*IOBuffer {
        const buf = if (self.free_list) |head| blk: {
            self.free_list = head.next_free;
            self.free_count -= 1;
            head.next_free = null;
            head.write_pos = 0;
            head.read_pos = 0;
            head.ref_count.store(1, .release);
            break :blk head;
        } else blk: {
            const new_buf = try self.allocator.create(IOBuffer);
            errdefer self.allocator.destroy(new_buf);
            const data = try self.allocator.alloc(u8, self.block_size);
            new_buf.* = .{
                .pool = self,
                .next_free = null,
                .capacity = self.block_size,
                .write_pos = 0,
                .read_pos = 0,
                .ref_count = std.atomic.Value(u32).init(1),
                .data = data.ptr,
            };
            break :blk new_buf;
        };

        self.in_use += 1;
        return buf;
    }

    pub fn release(self: *IOBufferPool, buf: *IOBuffer) void {
        //std.debug.assert(buf.pool == self);
        //std.debug.assert(buf.ref_count.load(.acquire) == 0);

        self.in_use -= 1;

        if (self.free_count >= self.max_free) {
            self.allocator.free(buf.data[0..buf.capacity]);
            self.allocator.destroy(buf);
            return;
        }

        buf.next_free = self.free_list;
        self.free_list = buf;
        self.free_count += 1;
    }
};

pub const IOBuffer = struct {
    pool: *IOBufferPool,
    next_free: ?*IOBuffer,
    capacity: usize,
    write_pos: usize,
    read_pos: usize,
    ref_count: std.atomic.Value(u32),
    data: [*]u8,

    pub fn ref(self: *IOBuffer) void {
        _ = self.ref_count.fetchAdd(1, .acq_rel);
    }

    pub fn unref(self: *IOBuffer) void {
        const count = self.ref_count.fetchSub(1, .acq_rel);
        if (count == 1) {
            self.write_pos = 0;
            self.read_pos = 0;
            self.pool.release(self);
        }
    }

    pub fn readable(self: *IOBuffer) []u8 {
        return self.data[self.read_pos..self.write_pos];
    }

    pub fn writable(self: *IOBuffer) []u8 {
        return self.data[self.write_pos..self.capacity];
    }

    pub fn advance_write(self: *IOBuffer, n: usize) void {
        std.debug.assert(self.write_pos + n <= self.capacity);
        self.write_pos += n;
    }

    pub fn advance_read(self: *IOBuffer, n: usize) void {
        std.debug.assert(self.read_pos + n <= self.write_pos);
        self.read_pos += n;
    }

    // returns a copy of the given buffer
    pub fn copy(self: *IOBuffer, copy_to: *IOBuffer) void {
        copy_to.write_pos = self.write_pos;
        copy_to.read_pos = self.read_pos;
        @memcpy(copy_to.data[self.read_pos..self.write_pos], self.data[self.read_pos..self.write_pos]);
    }
};
