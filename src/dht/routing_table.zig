const std = @import("std");
const message = @import("message.zig");
const DhtNodeId = message.DhtNodeId;
const DhtNodeEntry = message.DhtNodeEntry;

pub const DhtRoutingTable = struct {
    // long lived nodes
    //alive: std.MultiArrayList(DhtNodeEntry),
    alive: [256]std.BoundedArray(20, DhtNodeEntry),
    // replacement nodes

    pub fn init() DhtRoutingTable {
        return DhtRoutingTable{
            .alive = [256]std.BoundedArray(20, DhtNodeEntry){},
        };
    }

    // called when theres a sign of the node being alive
    pub fn nodeIsAlive(self: DhtRoutingTable, node: DhtNodeId, endpoint: std.net.Address) void {
        _ = self;
        _ = node;
        _ = endpoint;
    }
};
