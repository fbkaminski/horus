const std = @import("std");

// TODO: implement
pub const IOBufferPool = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    free_list: ?*IOBuffer, // intrusive: IOBuffer.next_free
    free_count: usize,
    max_free: usize,
    // stats — useful for debugging, ~free at runtime
    total_allocated: usize, // currently-live buffers (in freelist + checked out)
    in_use: usize, // checked out (derived would also work)
    peak_in_use: usize, // high water mark
    total_acquires: u64, // every acquire call, hit or miss
    total_allocs: u64, // acquire calls that allocated fresh

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
            .total_allocated = 0,
            .in_use = 0,
            .peak_in_use = 0,
            .total_acquires = 0,
            .total_allocs = 0,
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
        self.total_acquires += 1;
        const buf = if (self.free_list) |head| blk: {
            // Freelist hit: pop the head.
            self.free_list = head.next_free;
            self.free_count -= 1;
            head.next_free = null;
            head.write_pos = 0;
            head.read_pos = 0;
            // ref_count was zero in the freelist; bring it to 1.
            head.ref_count.store(1, .release);
            break :blk head;
        } else blk: {
            // Freelist miss: allocate.
            self.total_allocs += 1;
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
            self.total_allocated += 1;
            break :blk new_buf;
        };

        self.in_use += 1;
        //std.log.info("IOBufferPool.acquire: in_use = {}", .{self.in_use});
        if (self.in_use > self.peak_in_use) self.peak_in_use = self.in_use;
        return buf;
    }

    pub fn release(self: *IOBufferPool, buf: *IOBuffer) void {
        //std.debug.assert(buf.pool == self);
        //std.debug.assert(buf.ref_count.load(.acquire) == 0);

        self.in_use -= 1;

        if (self.free_count >= self.max_free) {
            // Freelist is full; free this buffer rather than holding it.
            self.allocator.free(buf.data[0..buf.capacity]);
            self.allocator.destroy(buf);
            self.total_allocated -= 1;
            return;
        }

        // Push at the head — O(1), LIFO (cache-friendly).
        buf.next_free = self.free_list;
        self.free_list = buf;
        self.free_count += 1;
    }

    pub fn stats(self: *const IOBufferPool) Stats {
        return .{
            .total_allocated = self.total_allocated,
            .in_use = self.in_use,
            .free_count = self.free_count,
            .peak_in_use = self.peak_in_use,
            .total_acquires = self.total_acquires,
            .total_allocs = self.total_allocs,
        };
    }

    pub const Stats = struct {
        total_allocated: usize,
        in_use: usize,
        free_count: usize,
        peak_in_use: usize,
        total_acquires: u64,
        total_allocs: u64,
    };
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
        self.ref_count.fetchAdd(1, .acq_rel);
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
        std.debug.assert(self.write_pos + n <= self.capacity);
        self.write_pos += n;
    }
    pub fn advance_read(self: *IOBuffer, n: usize) void {
        std.debug.assert(self.read_pos + n <= self.write_pos);
        self.read_pos += n;
    }
};
