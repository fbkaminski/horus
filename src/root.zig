//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const err = @import("dht/error.zig");
const host = @import("dht/host.zig");
const message = @import("dht/message.zig");
const routing_table = @import("dht/routing_table.zig");
const platform = @import("server/platform.zig");

pub const Platform = platform.Platform;
