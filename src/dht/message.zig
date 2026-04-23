const std = @import("std");

pub const DhtNodeId = [32]u8;
pub const DhtKey = [32]u8;

pub const DhtNodeEntry = struct {
    id: DhtNodeId,
    addr: std.net.Address,
};

pub const DhtMessageHeader = packed struct {
    magic: [4]u8,
    version: u8,
    msg_type: u4,
    flags: u4,
    transaction_id: u16,
    sender_id: DhtNodeId,
};

pub const DhtMessage = struct {
    header: DhtMessageHeader,
    payload: union(enum) {
        request: DhtRequest,
        response: DhtResponse,
    },
};

pub const DhtRequest = union(enum) {
    ping: void,
    store: struct {
        key: DhtKey,
        value: []const u8,
        signature: []u8,
        seq: i32,
    },
    find_node: struct { target: DhtNodeId },
    find_value: struct {
        key: DhtKey,
    },
};

pub const DhtResponse = union(enum) {
    pong: void,
    store_ok: void,
    nodes: struct {
        nodes: []const DhtNodeEntry,
    },
    // find_value can return either nodes or the value
    value: struct {
        value: []const u8,
    },
};
