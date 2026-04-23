const std = @import("std");
const io_linux = @import("../io/linux.zig");
const IO = io_linux.IO;

pub const NamedSocketConnection = struct {
    delegate: ?*NamedSocketDelegate,
    io: *IO,
    socket: std.posix.fd_t,
    closed: bool,
    recv_completion: IO.Completion,
    buf: [4096]u8,

    pub fn init(io: *IO, socket: std.posix.fd_t) NamedSocketConnection {
        var self: NamedSocketConnection = undefined;
        self.delegate = undefined;
        self.io = io;
        self.socket = socket;
        self.closed = false;
        self.recv_completion = .{
            .io = io,
            .operation = .{
                .recv = .{
                    .socket = self.socket,
                    .buffer = &self.buf,
                },
            },
            .context = &self,
            .callback = onDataCompletion,
        };
        return self;
    }

    pub fn deinit(self: *NamedSocketConnection) void {
        self.close();
    }

    pub fn setDelegate(self: *NamedSocketConnection, delegate: *NamedSocketDelegate) void {
        self.delegate = delegate;
        // arm the first recv as now we have a delegate to call back
        self.armRecv();
    }

    pub fn close(self: *NamedSocketConnection) void {
        if (!self.closed) {
            std.posix.close(self.socket);
            self.closed = true;
            self.delegate.?.onClose();
        }
    }

    fn onRecv(self: *NamedSocketConnection, _: *IO.Completion, result: IO.RecvError!usize) void {
        const n = result catch {
            std.log.err("NamedProcessChannel onRecv: error casting result to usize", .{});
            self.close();
            return;
        };
        if (n == 0) {
            // connection is gone
            self.close();
            return;
        }
        self.delegate.?.onRecv(self.buf[0..n]);
        self.armRecv();
    }

    fn armRecv(self: *NamedSocketConnection) void {
        self.io.recv(
            *NamedSocketConnection,
            self,
            onRecv,
            &self.recv_completion,
            self.socket,
            &self.buf,
        );
    }

    fn onDataCompletion(ctx: ?*anyopaque, _: *IO.Completion, result: *const anyopaque) void {
        std.debug.print("NamedProcessChannel.OnDataCompletion: doing nothing here, just asserting it was called", .{});
        _ = ctx;
        _ = result;
    }
};

pub const NamedServerSocketConnection = struct {
    delegate: *NamedServerSocketDelegate,
    io: *IO,
    socket: std.posix.fd_t,
    path: []const u8,
    closed: bool,
    accept_completion: IO.Completion,

    pub fn create(delegate: *NamedServerSocketDelegate, io: *IO, path: []const u8) !NamedServerSocketConnection {
        const socket = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(socket);

        // unlink in case it was serving at the same path before
        std.posix.unlink(path) catch {};

        return .{
            .delegate = delegate,
            .io = io,
            .socket = socket,
            .path = path,
            .closed = false,
            .accept_completion = undefined,
        };
    }

    pub fn deinit(self: *NamedServerSocketConnection) void {
        self.close();
    }

    pub fn close(self: *NamedServerSocketConnection) void {
        if (!self.closed) {
            std.posix.close(self.socket);
            self.closed = true;
            self.delegate.onClose();
        }
    }

    pub fn listen(self: *NamedServerSocketConnection) !void {
        // bind to path
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);

        const path_len = @min(self.path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.path[0..path_len]);

        try std.posix.bind(self.socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(self.socket, 16);
        try self.armAccept();
    }

    fn armAccept(self: *NamedServerSocketConnection) !void {
        self.io.accept(
            *NamedServerSocketConnection,
            self,
            onAccept,
            &self.accept_completion,
            self.socket,
        );
    }

    fn onAccept(self: *NamedServerSocketConnection, _: *IO.Completion, result: IO.AcceptError!std.posix.fd_t) void {
        const client_fd = result catch |err| {
            std.log.err("NamedServerSocketConnection onAccept: failed getting the accepted socket", .{});
            if (err == error.Canceled) return;
            try self.armAccept();
            return;
        };

        const conn = NamedSocketConnection.init(self.io, client_fd);
        // the delegate is responsible for the NamedSocketConnection ownership/cleanup
        self.delegate.onAccept(conn);

        try self.armAccept();
    }
};

pub const NamedSocketDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onClose: *const fn (ptr: *anyopaque) void,
        onRecv: *const fn (ptr: *anyopaque, data: []u8) void,
    };

    pub fn onClose(self: NamedSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onRecv(self: NamedSocketDelegate, data: []u8) void {
        self.vtable.onRecv(self.ptr, data);
    }
};

pub const NamedServerSocketDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onClose: *const fn (ptr: *anyopaque) void,
        onAccept: *const fn (ptr: *anyopaque, socket: NamedSocketConnection) void,
    };

    pub fn onClose(self: NamedServerSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onAccept(self: NamedServerSocketDelegate, socket: NamedSocketConnection) void {
        self.vtable.onAccept(self.ptr, socket);
    }
};
