const channel_file = @import("channel.zig");
const frame_file = @import("frame.zig");
const Frame = frame_file.Frame;
const Channel = channel_file.Channel;

pub const CrossProcessChannel = struct {
    // the base channel
    base: Channel,

    pub fn init(self: *CrossProcessChannel) void {
        self.base = .{
            .ptr = &self,
            .vtable = &vtable,
        };
    }

    pub fn channel(self: *CrossProcessChannel) *Channel {
        return &self.base;
    }

    pub fn send(self: *CrossProcessChannel, frame: *Frame) void {
        _ = self;
        _ = frame;
    }

    pub fn flush(self: *CrossProcessChannel) void {
        _ = self;
    }

    pub fn close(self: *CrossProcessChannel) void {
        _ = self;
    }

    const vtable = Channel.VTable{
        .send = struct {
            fn f(ptr: *anyopaque, frame: *Frame) void {
                const self: *CrossProcessChannel = @ptrCast(@alignCast(ptr));
                self.send(frame);
            }
        }.f,
        .flush = struct {
            fn f(ptr: *anyopaque) void {
                const self: *CrossProcessChannel = @ptrCast(@alignCast(ptr));
                self.flush();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *CrossProcessChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
    };
};
