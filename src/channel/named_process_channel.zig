const builtin = @import("builtin");
const std = @import("std");
const channel_file = @import("channel.zig");
const base = @import("../core/base.zig");
const io_linux = @import("../io/linux.zig");
const frame_file = @import("frame.zig");
const named_socket = @import("../net/named_socket.zig");
const Channel = channel_file.Channel;
const ChannelListener = channel_file.ChannelListener;
const ChannelMode = channel_file.ChannelMode;
const ChannelDelegate = channel_file.ChannelDelegate;
const ChannelListenerDelegate = channel_file.ChannelListenerDelegate;
const IO = io_linux.IO;
const Task = base.Task;
const TaskQueue = base.TaskQueue;
const NamedSocketConnection = named_socket.NamedSocketConnection;
const NamedServerSocketConnection = named_socket.NamedServerSocketConnection;
const NamedServerSocketDelegate = named_socket.NamedServerSocketDelegate;
const NamedSocketDelegate = named_socket.NamedSocketDelegate;
const Frame = frame_file.Frame;

// TODO: we need a ServerChannel with serve() as vtable method
//       but how to mix with the 'normal'/client  Channel?

// ALSO: for now this will be here but we need to find a better place
// as this can be used for any channel

/// A Named process server (named unix socket backed)
pub const NamedProcessServerChannel = struct {
    // the base channel
    base: ChannelListener,
    allocator: std.mem.Allocator,
    connection: NamedServerSocketConnection,
    socket_delegate: NamedServerSocketDelegate,
    delegate: *ChannelListenerDelegate,

    pub fn init(self: *NamedProcessServerChannel, allocator: std.mem.Allocator, path: []const u8, io: *IO, delegate: *ChannelListenerDelegate) !void {
        self.allocator = allocator;
        self.delegate = delegate;
        // fixme: we probably can do better here
        self.base = .{
            .ptr = self,
            .vtable = &listener_channel_vtable,
        };
        self.socket_delegate = .{
            .ptr = self,
            .vtable = &socket_delegate_vtable,
        };
        self.connection = try NamedServerSocketConnection.create(allocator, &self.socket_delegate, io, path);
    }

    pub fn serve(self: *NamedProcessServerChannel) !void {
        try self.connection.listen();
    }

    pub fn channel(self: *NamedProcessServerChannel) *ChannelListener {
        return &self.base;
    }

    pub fn mode(self: *NamedProcessServerChannel) ChannelMode {
        _ = self;
        return .SERVER;
    }
    pub fn close(self: *NamedProcessServerChannel) void {
        self.connection.close();
    }

    const listener_channel_vtable = ChannelListener.VTable{
        .mode = struct {
            fn f(ptr: *anyopaque) ChannelMode {
                const self: *NamedProcessServerChannel = @ptrCast(@alignCast(ptr));
                return self.mode();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessServerChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
        .listen = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessServerChannel = @ptrCast(@alignCast(ptr));
                // fixme: dont ignore errors here (how to broadcast forward)
                self.serve() catch return;
            }
        }.f,
    };

    const socket_delegate_vtable = NamedServerSocketDelegate.VTable{
        .onAccept = struct {
            fn f(ptr: *anyopaque, socket: *NamedSocketConnection) void {
                const self: *NamedProcessServerChannel = @ptrCast(@alignCast(ptr));
                const client = NamedProcessChannel.init(self.allocator, socket) catch return;
                self.delegate.onConnection(&self.base, &client.base);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessServerChannel = @ptrCast(@alignCast(ptr));
                self.delegate.onClose(&self.base);
            }
        }.f,
    };
};

pub const NamedProcessChannel = struct {
    // the base channel
    base: Channel,
    allocator: std.mem.Allocator,
    connection: *NamedSocketConnection,
    socket_delegate: NamedSocketDelegate,
    delegate: ?*ChannelDelegate,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: *NamedSocketConnection,
    ) !*NamedProcessChannel {
        const self = try allocator.create(NamedProcessChannel);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .delegate = null,
            .base = .{
                .ptr = self,
                .vtable = &vtable,
            },
            .socket_delegate = .{
                .ptr = self,
                .vtable = &socket_delegate_vtable,
            },
        };
        self.connection.setDelegate(&self.socket_delegate);
        return self;
    }

    pub fn setDelegate(self: *NamedProcessChannel, delegate: *ChannelDelegate) void {
        self.delegate = delegate;
    }

    pub fn deinit(self: *NamedProcessChannel) void {
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    pub fn channel(self: *NamedProcessChannel) *Channel {
        return &self.base;
    }

    pub fn mode(self: *NamedProcessChannel) ChannelMode {
        _ = self;
        return .CLIENT;
    }

    pub fn upgrade(self: *NamedProcessChannel) void {
        _ = self;
    }

    pub fn send(self: *NamedProcessChannel, frame: *Frame) void {
        _ = self;
        _ = frame;
    }

    pub fn flush(self: *NamedProcessChannel) void {
        _ = self;
    }

    pub fn close(self: *NamedProcessChannel) void {
        self.connection.close();
    }

    const vtable = Channel.VTable{
        .mode = struct {
            fn f(ptr: *anyopaque) ChannelMode {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                return self.mode();
            }
        }.f,
        .upgrade = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                return self.upgrade();
            }
        }.f,
        .send = struct {
            fn f(ptr: *anyopaque, frame: *Frame) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                self.send(frame);
            }
        }.f,
        .flush = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                self.flush();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
    };

    const socket_delegate_vtable = NamedSocketDelegate.VTable{
        .onRecv = struct {
            fn f(ptr: *anyopaque, data: []u8) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                self.delegate.?.onDataAvailable(&self.base, data);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                self.delegate.?.onConnectionClosed(&self.base);
            }
        }.f,
    };
};
