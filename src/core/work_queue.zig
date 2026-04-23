const std = @import("std");

pub fn WorkQueue(comptime T: type) type {
    return struct {
        pub const Node = struct {
            next: std.atomic.Value(?*Node) = .{ .raw = null },
            value: T,
        };

        head: std.atomic.Value(?*Node) = .{ .raw = null },
        tail: ?*Node = null,

        pub fn push(self: *@This(), node: *Node) void {
            node.next.store(null, .release);
            const prev = self.head.swap(node, .acq_rel);
            if (prev) |p| {
                p.next.store(node, .release);
            } else {
                self.tail = node;
            }
        }

        pub fn pop(self: *@This()) ?*Node {
            const tail = self.tail orelse return null;
            if (tail.next.load(.acquire)) |next| {
                self.tail = next;
                return tail;
            }
            // tail == head: queue is empty or mid-push
            if (self.head.load(.acquire) != tail) return null;
            self.tail = null;
            _ = self.head.cmpxchgStrong(tail, null, .acq_rel, .acquire);
            return tail;
        }
    };
}
