const in_process_channel_file = @import("../channel/in_process_channel.zig");
const InProcessChannel = in_process_channel_file.InProcessChannel;

pub const BuiltinModule = struct {
    channel: InProcessChannel,
};
