const builtin = @import("builtin");
const std = @import("std");
const channel_file = @import("channel.zig");
const base = @import("../core/base.zig");
const frame_file = @import("frame.zig");
const named_socket = @import("../net/named_socket.zig");
const io_buffer = @import("../net/io_buffer.zig");
const io_file = if (builtin.os.tag == .linux) @import("../io/linux.zig") else @import("../io/darwin.zig");
const IO = io_file.IO;
const Channel = channel_file.Channel;
const ChannelListener = channel_file.ChannelListener;
const ChannelMode = channel_file.ChannelMode;
const ChannelDelegate = channel_file.ChannelDelegate;
const ChannelListenerDelegate = channel_file.ChannelListenerDelegate;
const Task = base.Task;
const TaskQueue = base.TaskQueue;
const NamedSocket = named_socket.NamedSocket;
const NamedServerSocket = named_socket.NamedServerSocket;
const NamedServerSocketDelegate = named_socket.NamedServerSocketDelegate;
const NamedSocketDelegate = named_socket.NamedSocketDelegate;
const Frame = frame_file.Frame;
const IOBuffer = io_buffer.IOBuffer;

/// A Named process server (named unix socket backed)
pub const NamedProcessServerChannel = struct {
    // the base channel
    base: ChannelListener,
    allocator: std.mem.Allocator,
    connection: NamedServerSocket,
    socket_delegate: NamedServerSocketDelegate,
    delegate: *ChannelListenerDelegate,

    pub fn init(self: *NamedProcessServerChannel, allocator: std.mem.Allocator, path: []const u8, io: *IO, delegate: *ChannelListenerDelegate) !void {
        self.allocator = allocator;
        self.delegate = delegate;
        self.base = .{
            .ptr = self,
            .vtable = &listener_channel_vtable,
        };
        self.socket_delegate = .{
            .ptr = self,
            .vtable = &socket_delegate_vtable,
        };
        self.connection = try NamedServerSocket.create(allocator, &self.socket_delegate, io, path);
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
            fn f(ptr: *anyopaque, socket: *NamedSocket) void {
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
    connection: *NamedSocket,
    socket_delegate: NamedSocketDelegate,
    delegate: ?*ChannelDelegate,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: *NamedSocket,
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
        return self;
    }

    pub fn setDelegate(self: *NamedProcessChannel, delegate: ?*ChannelDelegate) void {
        self.delegate = delegate;
        if (delegate == null) {
            self.connection.setDelegate(null);
        } else {
            self.connection.setDelegate(&self.socket_delegate);
        }
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
        .onConnection = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnection(&self.base);
            }
        }.f,
        .onConnectionFailed = struct {
            fn f(ptr: *anyopaque, err: IO.ConnectError) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnectionFailed(&self.base, err);
            }
        }.f,
        .onDisconnect = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onDisconnect(&self.base);
            }
        }.f,
        .onRecv = struct {
            fn f(ptr: *anyopaque, buffer: *IOBuffer) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onReceive(&self.base, buffer);
            }
        }.f,
        .onRecvFailed = struct {
            fn f(ptr: *anyopaque, err: IO.RecvError) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onReceiveFailed(&self.base, err);
            }
        }.f,
        .onSend = struct {
            fn f(ptr: *anyopaque, sent: usize) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onSend(&self.base, sent);
            }
        }.f,
        .onSendFailed = struct {
            fn f(ptr: *anyopaque, err: IO.SendError) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onSendFailed(&self.base, err);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedProcessChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnectionClosed(&self.base);
            }
        }.f,
    };
};
