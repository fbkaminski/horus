const message = @import("message.zig");
const DhtMessage = message.DhtMessage;

pub const CborCodec = struct {
    pub fn init() CborCodec {
        return CborCodec{};
    }
    pub fn decode(self: *CborCodec, data: []const u8) !DhtMessage {
        _ = self;
        _ = data;
    }
};
