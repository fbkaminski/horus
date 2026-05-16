const builtin = @import("builtin");
const std = @import("std");
const channel_file = @import("channel.zig");
const core = @import("../core/core.zig");
const frame_file = @import("frame.zig");
const net_file = @import("../net/net.zig");
const IO = @import("../io/io.zig").IO;
const Channel = channel_file.Channel;
const ChannelListener = channel_file.ChannelListener;
const ChannelMode = channel_file.ChannelMode;
const ChannelDelegate = channel_file.ChannelDelegate;
const ChannelListenerDelegate = channel_file.ChannelListenerDelegate;
const Task = core.Task;
const TaskQueue = core.TaskQueue;
const NamedSocket = net_file.NamedSocket;
const NamedServerSocket = net_file.NamedServerSocket;
const Socket = net_file.Socket;
const ServerSocketDelegate = net_file.ServerSocketDelegate;
const SocketDelegate = net_file.SocketDelegate;
const Frame = frame_file.Frame;
const IOBuffer = net_file.IOBuffer;
const IOBufferPool = net_file.IOBufferPool;

/// IpcChannel/IpcServerChannel over a Socket/ServerSocket => (Named or Threaded)
pub const IpcServerChannel = struct {
    // the base channel
    base: ChannelListener,
    allocator: std.mem.Allocator,
    connection: *NamedServerSocket,
    socket_delegate: ServerSocketDelegate,
    delegate: *ChannelListenerDelegate,

    pub fn init(self: *IpcServerChannel, allocator: std.mem.Allocator, io: *IO, pool: *IOBufferPool, delegate: *ChannelListenerDelegate) !void {
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
        self.connection = try allocator.create(NamedServerSocket);
        self.connection.init(allocator, &self.socket_delegate, io, pool);
    }

    pub fn deinit(self: *IpcServerChannel) void {
        self.connection.deinit();
    }

    pub fn serve(self: *IpcServerChannel, path: []const u8) void {
        self.connection.listen(.{ .path = path });
    }

    pub fn channel(self: *IpcServerChannel) *ChannelListener {
        return &self.base;
    }

    pub fn mode(self: *IpcServerChannel) ChannelMode {
        _ = self;
        return .SERVER;
    }
    pub fn close(self: *IpcServerChannel) void {
        self.connection.close();
    }

    const listener_channel_vtable = ChannelListener.VTable{
        .mode = struct {
            fn f(ptr: *anyopaque) ChannelMode {
                const self: *IpcServerChannel = @ptrCast(@alignCast(ptr));
                return self.mode();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcServerChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
        .listen = struct {
            fn f(ptr: *anyopaque, path: []const u8) void {
                const self: *IpcServerChannel = @ptrCast(@alignCast(ptr));
                self.serve(path);
            }
        }.f,
    };

    const socket_delegate_vtable = ServerSocketDelegate.VTable{
        .onAccept = struct {
            fn f(ptr: *anyopaque, socket: *Socket) void {
                const self: *IpcServerChannel = @ptrCast(@alignCast(ptr));
                const client = IpcChannel.init(self.allocator, socket) catch return;
                self.delegate.onConnection(&self.base, &client.base);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcServerChannel = @ptrCast(@alignCast(ptr));
                self.delegate.onClose(&self.base);
            }
        }.f,
    };
};

pub const IpcChannel = struct {
    // the base channel
    base: Channel,
    allocator: std.mem.Allocator,
    connection: *Socket,
    socket_delegate: SocketDelegate,
    delegate: ?*ChannelDelegate,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: *Socket,
    ) !*IpcChannel {
        const self = try allocator.create(IpcChannel);
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

    pub fn setDelegate(self: *IpcChannel, delegate: ?*ChannelDelegate) void {
        self.delegate = delegate;
        if (delegate == null) {
            self.connection.setDelegate(null);
        } else {
            self.connection.setDelegate(&self.socket_delegate);
        }
    }

    pub fn deinit(self: *IpcChannel) void {
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    pub fn channel(self: *IpcChannel) *Channel {
        return &self.base;
    }

    pub fn mode(self: *IpcChannel) ChannelMode {
        _ = self;
        return .CLIENT;
    }

    pub fn upgrade(self: *IpcChannel) void {
        _ = self;
    }

    pub fn send(self: *IpcChannel, frame: *Frame) void {
        _ = self;
        _ = frame;
    }

    pub fn flush(self: *IpcChannel) void {
        _ = self;
    }

    pub fn close(self: *IpcChannel) void {
        self.connection.close();
    }

    const vtable = Channel.VTable{
        .mode = struct {
            fn f(ptr: *anyopaque) ChannelMode {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                return self.mode();
            }
        }.f,
        .upgrade = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                return self.upgrade();
            }
        }.f,
        .send = struct {
            fn f(ptr: *anyopaque, frame: *Frame) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                self.send(frame);
            }
        }.f,
        .flush = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                self.flush();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
    };

    const socket_delegate_vtable = SocketDelegate.VTable{
        .onConnection = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnection(&self.base);
            }
        }.f,
        .onConnectionFailed = struct {
            fn f(ptr: *anyopaque, err: IO.ConnectError) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnectionFailed(&self.base, err);
            }
        }.f,
        .onDisconnect = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onDisconnect(&self.base);
            }
        }.f,
        .onRecv = struct {
            fn f(ptr: *anyopaque, buffer: *IOBuffer) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onReceive(&self.base, buffer);
            }
        }.f,
        .onRecvFailed = struct {
            fn f(ptr: *anyopaque, err: IO.RecvError) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onReceiveFailed(&self.base, err);
            }
        }.f,
        .onSend = struct {
            fn f(ptr: *anyopaque, sent: usize) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onSend(&self.base, sent);
            }
        }.f,
        .onSendFailed = struct {
            fn f(ptr: *anyopaque, err: IO.SendError) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onSendFailed(&self.base, err);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *IpcChannel = @ptrCast(@alignCast(ptr));
                if (self.delegate) |d| d.onConnectionClosed(&self.base);
            }
        }.f,
    };
};
