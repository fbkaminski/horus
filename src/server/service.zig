const std = @import("std");
const dht_message = @import("../dht/message.zig");
const DhtNodeId = dht_message.DhtNodeId;

// represents a service
pub const ServiceId = u64;

pub const CapToken = [64]u8;

pub const InterfaceId = [32]u8; // SHA 256 of IDL

/// A registered service
pub const ServiceHandle = struct {
    id: ServiceId,
    interface_id: InterfaceId,
    node_id: DhtNodeId,
    generation: u32,
    channel_fd: std.posix.fd_t,
    capability: CapToken,
};
