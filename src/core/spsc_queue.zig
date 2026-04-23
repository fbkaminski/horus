const std = @import("std");

pub fn SPSCQueue(comptime T: type) type {
    return extern struct {
        head: Atomic(usize) align(cache_line),
        cached_tail: usize,
        _consumer_pad: [padding_size(2 * @sizeOf(usize))]u8,
        tail: Atomic(usize) align(cache_line),
        cached_head: usize,
        _producer_pad: [padding_size(2 * @sizeOf(usize))]u8,
        buffer: [*]T,
        mask: usize,
        capacity: usize,

        const Self = @This();
        const Atomic = std.atomic.Value;
        const cache_line = std.atomic.cache_line;

        /// Calculate padding to fill rest of cache line
        fn padding_size(used: usize) usize {
            const remainder = used % cache_line;
            return if (remainder == 0) 0 else cache_line - remainder;
        }

        pub fn init(allocator: std.mem.Allocator, requested_cap: usize) !Self {
            const actual_cap = std.math.ceilPowerOfTwo(usize, requested_cap + 1) catch return error.CapacityTooLarge;
            const buffer = try allocator.alignedAlloc(T, std.mem.Alignment.fromByteUnits(cache_line), actual_cap);
            errdefer allocator.free(buffer);

            return Self{
                .head = Atomic(usize).init(0),
                .cached_tail = 0,
                ._consumer_pad = undefined,
                .tail = Atomic(usize).init(0),
                .cached_head = 0,
                ._producer_pad = undefined,
                .buffer = buffer.ptr,
                .mask = actual_cap - 1,
                .capacity = actual_cap,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const slice = self.buffer[0..self.capacity];
            allocator.free(slice);
        }

        /// User-visible capacity
        pub fn userCapacity(self: *const Self) usize {
            return self.capacity - 1;
        }

        /// Fast index wrapping using mask or modulo
        inline fn wrapIndex(self: *const Self, idx: usize) usize {
            return idx & self.mask;
        }

        /// Non-blocking push. Returns true on success.
        pub fn tryPush(self: *Self, value: T) bool {
            const current_tail = self.tail.load(.monotonic);
            const next_tail = self.wrapIndex(current_tail + 1);

            // Fast path: check cached head
            if (next_tail == self.cached_head) {
                self.cached_head = self.head.load(.acquire);
                if (next_tail == self.cached_head) {
                    return false; // Queue full
                }
            }

            // Write data
            self.buffer[current_tail] = value;

            // Publish with release semantics
            self.tail.store(next_tail, .release);

            return true;
        }

        /// Blocking push
        pub fn push(self: *Self, value: T) void {
            while (!self.tryPush(value)) {
                std.atomic.spinLoopHint();
            }
        }

        /// Non-blocking pop. Returns true and writes to out on success.
        pub fn tryPop(self: *Self, out: *T) bool {
            const current_head = self.head.load(.monotonic);

            // Fast path: check cached tail
            if (current_head == self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (current_head == self.cached_tail) {
                    return false; // Queue empty
                }
            }

            // Read data
            out.* = self.buffer[current_head];

            // Publish with release semantics
            const next_head = self.wrapIndex(current_head + 1);
            self.head.store(next_head, .release);

            return true;
        }

        /// Peek at the next item without consuming it.
        /// Returns a pointer to the slot so the caller can read it before
        /// deciding to pop. The pointer is only valid until the next pop().
        pub fn front(self: *Self) ?*T {
            const current_head = self.head.load(.monotonic);

            // Same empty check as tryPop — use cached_tail first,
            // reload with acquire only if cache says empty.
            if (current_head == self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (current_head == self.cached_tail) {
                    return null; // empty
                }
            }

            return &self.buffer[current_head];
        }

        /// Convenience: returns optional value
        pub fn pop(self: *Self) ?T {
            var value: T = undefined;
            if (self.tryPop(&value)) {
                return value;
            }
            return null;
        }

        /// Batch push: attempts to push multiple items at once
        /// Returns number of items successfully pushed
        pub fn tryPushBatch(self: *Self, items: []const T) usize {
            var pushed: usize = 0;
            const current_tail = self.tail.load(.monotonic);

            // Refresh head cache once
            self.cached_head = self.head.load(.acquire);

            for (items) |item| {
                const next_tail = self.wrapIndex(current_tail + pushed + 1);
                if (next_tail == self.cached_head) {
                    break; // Would be full
                }

                self.buffer[self.wrapIndex(current_tail + pushed)] = item;
                pushed += 1;
            }

            if (pushed > 0) {
                const new_tail = self.wrapIndex(current_tail + pushed);
                self.tail.store(new_tail, .release);
            }

            return pushed;
        }

        /// Batch pop: attempts to pop multiple items at once
        /// Returns number of items successfully popped
        pub fn tryPopBatch(self: *Self, out: []T) usize {
            var popped: usize = 0;
            const current_head = self.head.load(.monotonic);

            // Refresh tail cache once
            self.cached_tail = self.tail.load(.acquire);

            for (out) |*item| {
                const item_head = self.wrapIndex(current_head + popped);
                if (item_head == self.cached_tail) {
                    break; // Would be empty
                }

                item.* = self.buffer[item_head];
                popped += 1;
            }

            if (popped > 0) {
                const new_head = self.wrapIndex(current_head + popped);
                self.head.store(new_head, .release);
            }

            return popped;
        }

        /// Check if queue is empty (may race with concurrent operations)
        pub fn isEmpty(self: *const Self) bool {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return h == t;
        }

        /// Get approximate size (may race with concurrent operations)
        pub fn size(self: *const Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);

            if (t >= h) {
                return t - h;
            } else {
                return self.capacity - h + t;
            }
        }
    };
}
