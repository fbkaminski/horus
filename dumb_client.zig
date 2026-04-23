const std = @import("std");

pub fn main() !void {
    const sock = try std.net.connectUnixSocket("/tmp/dht_host.sock");
    defer sock.close();

    // send something recognizable in your debug output
    try sock.writeAll("PING");
    std.debug.print("sent, waiting...\n", .{});
}
