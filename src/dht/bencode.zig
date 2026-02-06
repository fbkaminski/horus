const message = @import("message.zig");
const DhtMessage = message.DhtMessage;

pub const BencodeCodec = struct {
    pub fn init() BencodeCodec {
        return BencodeCodec{};
    }
    pub fn decode(self: *BencodeCodec, data: []const u8) !DhtMessage {}
};
