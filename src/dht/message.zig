const std = @import("std");

pub const NodeId = [32]u8; // or [20]u8 for 160-bit
pub const Key = [32]u8;

pub const NodeInfo = struct {
    id: NodeId,
    addr: std.net.Address,
};

pub const DhtMessage = struct {
    transaction_id: u16,
    sender_id: NodeId,

    payload: union(enum) {
        request: DhtRequest,
        response: DhtResponse,
    },
};

pub const DhtRequest = union(enum) {
    ping: void,
    get_peers: struct {
        info_hash: Key,
        noseed: ?bool,
        scrape: ?bool,
        want: ?[]NodeId,
    },
    find_node: struct {
        target: NodeId,
        want: ?[]NodeId,
    },
    announce_peer: struct {
        infohash: Key,
        port: i16,
        token: []u8,
        n: ?[]u8,
        seed: ?i32,
        implied_port: ?i16,
    },
    put: struct {
        key: Key,
        value: []const u8,
        // mutable puts
        seq: ?i32,
        pubkey: ?[]u8,
        signature: ?[]u8,
        cas: ?i32,
        salt: ?[]u8,
    },
    get: struct {
        key: Key,
        seq: ?i32,
        want: ?[]NodeId,
    },
};

pub const DhtResponse = union(enum) {
    pong: void,
    store_ok: void,
    nodes: struct {
        nodes: []const NodeInfo,
    },
    // find_value can return either nodes or the value
    value: struct {
        value: []const u8,
    },
};
