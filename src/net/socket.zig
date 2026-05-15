const std = @import("std");
const IO = @import("../io/io.zig").IO;
const IOBuffer = @import("io_buffer.zig").IOBuffer;

pub const SocketState = enum {
    init,
    opening,
    open,
    closing,
    closed,
};

pub const SocketConnectionArgsTag = enum {
    path,
};

pub const SocketConnectionArgs = union(SocketConnectionArgsTag) {
    path: []const u8,
};

pub const Socket = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        connect: *const fn (ptr: *anyopaque, args: SocketConnectionArgs) void,
        close: *const fn (ptr: *anyopaque) void,
        send: *const fn (ptr: *anyopaque, buf: *IOBuffer) void,
        accept: *const fn (ptr: *anyopaque, socket: std.posix.fd_t) void,
        setDelegate: *const fn (ptr: *anyopaque, delegate: ?*SocketDelegate) void,
    };

    pub fn deinit(self: Socket) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn setDelegate(self: Socket, delegate: ?*SocketDelegate) void {
        self.vtable.setDelegate(self.ptr, delegate);
    }

    pub fn connect(self: Socket, args: SocketConnectionArgs) void {
        self.vtable.connect(self.ptr, args);
    }

    pub fn close(self: Socket) void {
        self.vtable.close(self.ptr);
    }

    pub fn send(self: Socket, buf: *IOBuffer) void {
        self.vtable.send(self.ptr, buf);
    }

    pub fn accept(self: Socket, socket: std.posix.fd_t) void {
        self.vtable.accept(self.ptr, socket);
    }
};

pub const ServerSocketState = enum {
    init,
    opening,
    open,
    listening,
    closing,
    closed,
};

pub const ServerSocketListenArgsTag = enum {
    path,
};

pub const ServerSocketListenArgs = union(ServerSocketListenArgsTag) {
    path: []const u8,
};

pub const ServerSocket = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
        listen: *const fn (ptr: *anyopaque, args: ServerSocketListenArgs) void,
    };

    pub fn deinit(self: Socket) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn listen(self: Socket, args: ServerSocketListenArgs) void {
        self.vtable.listen(self.ptr, args);
    }

    pub fn close(self: Socket) void {
        self.vtable.close(self.ptr);
    }
};

pub const SocketDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onConnection: *const fn (ptr: *anyopaque) void,
        onConnectionFailed: *const fn (ptr: *anyopaque, err: IO.ConnectError) void,
        onDisconnect: *const fn (ptr: *anyopaque) void,
        onClose: *const fn (ptr: *anyopaque) void,
        onRecv: *const fn (ptr: *anyopaque, buffer: *IOBuffer) void,
        onRecvFailed: *const fn (ptr: *anyopaque, err: IO.RecvError) void,
        onSend: *const fn (ptr: *anyopaque, sent: usize) void,
        onSendFailed: *const fn (ptr: *anyopaque, err: IO.SendError) void,
    };

    pub fn onConnection(self: SocketDelegate) void {
        self.vtable.onConnection(self.ptr);
    }

    pub fn onConnectionFailed(self: SocketDelegate, err: IO.ConnectError) void {
        self.vtable.onConnectionFailed(self.ptr, err);
    }

    pub fn onDisconnect(self: SocketDelegate) void {
        self.vtable.onDisconnect(self.ptr);
    }

    pub fn onClose(self: SocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onRecv(self: SocketDelegate, buffer: *IOBuffer) void {
        self.vtable.onRecv(self.ptr, buffer);
    }

    pub fn onRecvFailed(self: SocketDelegate, err: IO.RecvError) void {
        self.vtable.onRecvFailed(self.ptr, err);
    }

    pub fn onSend(self: SocketDelegate, sent: usize) void {
        self.vtable.onSend(self.ptr, sent);
    }

    pub fn onSendFailed(self: SocketDelegate, err: IO.SendError) void {
        self.vtable.onSendFailed(self.ptr, err);
    }
};

pub const ServerSocketDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onClose: *const fn (ptr: *anyopaque) void,
        onAccept: *const fn (ptr: *anyopaque, socket: *Socket) void,
    };

    pub fn onClose(self: ServerSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onAccept(self: ServerSocketDelegate, socket: *Socket) void {
        self.vtable.onAccept(self.ptr, socket);
    }
};
