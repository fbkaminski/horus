const std = @import("std");

// TODO: implement
pub const IOBufferPool = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    free_list: ?*IOBuffer, // intrusive: IOBuffer.next_free
    free_count: usize,
    high_water: usize,

    pub fn init(allocator: std.mem.Allocator, block_size: usize) IOBufferPool {
        return IOBufferPool{
            .allocator = allocator,
            .block_size = block_size,
            .free_list = null,
            .free_count = 0,
            .high_water = 10 * block_size,
        };
    }

    pub fn deinit(self: *IOBufferPool) void {
        _ = self;
    }

    pub fn acquire(self: *IOBufferPool) !*IOBuffer {
        _ = self;
    }

    pub fn release(self: *IOBufferPool, buf: *IOBuffer) void {
        _ = self;
        _ = buf;
    }
};

pub const IOBuffer = struct {
    pool: *IOBufferPool,
    next_free: ?*IOBuffer, // freelist link for IOBufferPool
    capacity: usize,
    write_pos: usize,
    read_pos: usize,
    ref_count: std.atomic.Value(u32),
    data: [*]u8,

    pub fn ref(self: *IOBuffer) void {
        _ = self.ref_count.fetchAdd(1, .acq_rel);
    }

    pub fn unref(self: *IOBuffer) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
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
        self.write_pos += n;
    }
    pub fn advance_read(self: *IOBuffer, n: usize) void {
        self.read_pos += n;
    }
};
