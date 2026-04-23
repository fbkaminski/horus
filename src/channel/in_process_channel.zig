const channel_file = @import("channel.zig");
const frame_file = @import("frame.zig");
const Frame = frame_file.Frame;
const Channel = channel_file.Channel;

pub const InProcessChannel = struct {
    // the base channel
    base: Channel,

    pub fn channel(self: *InProcessChannel) *Channel {
        return &self.base;
    }

    pub fn send(self: *InProcessChannel, frame: *Frame) void {
        _ = self;
        _ = frame;
    }

    pub fn flush(self: *InProcessChannel) void {
        _ = self;
    }

    pub fn close(self: *InProcessChannel) void {
        _ = self;
    }
};

pub const InProcessServerChannel = struct {
    base: InProcessChannel,

    pub fn init(self: *InProcessServerChannel) void {
        self.base = .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn send(self: *InProcessServerChannel, frame: *Frame) void {
        self.base.send(frame);
    }

    pub fn flush(self: *InProcessServerChannel) void {
        self.base.flush();
    }

    pub fn close(self: *InProcessServerChannel) void {
        self.base.close();
    }

    pub fn channel(self: *InProcessServerChannel) *Channel {
        return self.base.channel();
    }

    const vtable = Channel.VTable{
        .send = struct {
            fn f(ptr: *anyopaque, frame: *Frame) void {
                const self: *InProcessServerChannel = @ptrCast(@alignCast(ptr));
                self.send(frame);
            }
        }.f,
        .flush = struct {
            fn f(ptr: *anyopaque) void {
                const self: *InProcessServerChannel = @ptrCast(@alignCast(ptr));
                self.flush();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *InProcessServerChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
    };
};
