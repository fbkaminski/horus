const std = @import("std");
const builtin = @import("builtin");
const io_file = if (builtin.os.tag == .linux) @import("../io/linux.zig") else @import("../io/darwin.zig");
const io_buffer = @import("io_buffer.zig");
const IO = io_file.IO;
const IOBuffer = io_buffer.IOBuffer;
const IOBufferPool = io_buffer.IOBufferPool;

const ConnectionState = enum {
    init,
    opening,
    open,
    closing,
    closed,
};

pub const NamedSocket = struct {
    allocator: std.mem.Allocator,
    delegate: ?*NamedSocketDelegate,
    io: *IO,
    socket: ?std.posix.fd_t,
    recv_completion: IO.Completion,
    cancel_completion: IO.Completion,
    connect_completion: IO.Completion,
    write_completion: IO.Completion,
    recv_buf: ?*IOBuffer,
    write_buf: ?*IOBuffer,
    buffer_pool: IOBufferPool,
    state: ConnectionState,
    pending_ops: u8,
    // whether the io backend supports cancelation
    io_supports_cancellation: bool,

    pub fn init(allocator: std.mem.Allocator, io: *IO) *NamedSocket {
        var self = allocator.create(NamedSocket) catch return undefined;
        self.allocator = allocator;
        self.delegate = null;
        self.io = io;
        self.socket = null;
        self.recv_buf = null;
        self.write_buf = null;
        self.buffer_pool = IOBufferPool.init(allocator, .{});
        self.state = .init;
        self.pending_ops = 0;
        if (builtin.os.tag == .linux) {
            self.io_supports_cancellation = true;
        } else if (builtin.os.tag == .macos) {
            self.io_supports_cancellation = false;
        }
        return self;
    }

    pub fn connect(self: *NamedSocket, path: []const u8) !void {
        self.state = .opening;
        const address = try std.net.Address.initUnix(path);
        const sock = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        self.socket = sock;
        self.incrementPendingOps();
        self.io.connect(
            *NamedSocket,
            self,
            onConnect,
            &self.connect_completion,
            sock,
            address,
        );
    }

    pub fn deinit(self: *NamedSocket) void {
        self.delegate = null;
        self.closeSocket();
        self.finalize();
    }

    pub fn setDelegate(self: *NamedSocket, delegate: ?*NamedSocketDelegate) void {
        self.delegate = delegate;
    }

    pub fn close(self: *NamedSocket) void {
        if (self.state == .closing) {
            return;
        }

        self.state = .closing;

        if (self.io_supports_cancellation and self.pending_ops > 0) {
            self.io.cancel(
                *NamedSocket,
                self,
                onCancelComplete,
                .{
                    .completion = &self.cancel_completion,
                    .target = &self.recv_completion,
                },
            );
            self.incrementPendingOps();
        } else {
            // this should be always 0 if io_supports_cancellation is false
            std.debug.assert(self.pending_ops == 0);
            self.closeSocket();
        }
    }

    pub fn send(self: *NamedSocket, buf: *IOBuffer) void {
        self.write_buf = buf;
        // we are owning it temporarily now, so refcount it
        self.write_buf.?.ref();
        const data = self.write_buf.?.readable();
        self.incrementPendingOps();
        self.io.send(
            *NamedSocket,
            self,
            onSend,
            &self.write_completion,
            self.socket.?,
            data,
        );
    }

    fn accept(self: *NamedSocket, socket: std.posix.fd_t) void {
        self.socket = socket;
        self.state = .open;
        if (builtin.os.tag == .linux) {
            self.recv_completion = .{
                .io = self.io,
                .operation = .{
                    .recv = .{
                        .socket = self.socket.?,
                        .buffer = undefined,
                    },
                },
                .context = self,
                .callback = onDataCompletionLinux,
            };
        } else if (builtin.os.tag == .macos) {
            self.recv_completion = .{
                .operation = .{
                    .recv = .{
                        .socket = self.socket.?,
                        .buffer = undefined,
                        .len = 0,
                    },
                },
                .context = self,
                .callback = onDataCompletionDarwin,
            };
        }
        // allocate the recv buffer
        self.recv_buf = self.buffer_pool.acquire() catch return;
        // arm the first recv after being sucessfully connected
        self.armRecv();
    }

    fn closeSocket(self: *NamedSocket) void {
        if (self.state == .closed) {
            return;
        }
        if (self.pending_ops != 0) return;
        self.closeNativeSocket();
        if (self.delegate) |d| d.onClose();
    }

    fn closeNativeSocket(self: *NamedSocket) void {
        if (comptime builtin.os.tag == .macos) {
            self.io.close_socket(self.socket.?);
        } else {
            std.posix.close(self.socket.?);
        }
        self.state = .closed;
    }

    fn onConnect(self: *NamedSocket, _: *IO.Completion, err: IO.ConnectError!void) void {
        err catch |e| {
            if (self.delegate) |d| d.onConnectionFailed(e);
            self.state = .closing;
            return;
        };
        self.state = .open;
        if (self.delegate) |d| d.onConnection();

        // allocate the recv buffer
        self.recv_buf = self.buffer_pool.acquire() catch return;

        // arm the first recv after being sucessfully connected
        self.armRecv();
        self.decrementPendingOps();
    }

    fn onCancelComplete(self: *NamedSocket, _: *IO.Completion, _: IO.CancelError!void) void {
        self.decrementPendingOps();
        self.closeSocket();
    }

    fn onSend(self: *NamedSocket, _: *IO.Completion, result: IO.SendError!usize) void {
        if (self.write_buf) |buf| {
            buf.unref();
            self.write_buf = null;
        }
        const size = result catch |e| {
            if (self.delegate) |d| d.onSendFailed(e);
            return;
        };
        //std.log.info("send completion: wrote {} bytes", .{size});
        if (self.delegate) |d| d.onSend(size);
        self.decrementPendingOps();
    }

    fn onRecv(self: *NamedSocket, _: *IO.Completion, result: IO.RecvError!usize) void {
        self.decrementPendingOps();
        if (self.state == .closing) {
            self.closeSocket();
            return;
        }
        const n = result catch |e| {
            if (self.delegate) |d| d.onRecvFailed(e);
            self.close();
            return;
        };
        if (n == 0) {
            // connection is gone
            if (self.delegate) |d| d.onDisconnect();
            self.close();
            return;
        }
        if (self.recv_buf) |buf| {
            buf.advance_write(n);
            if (self.delegate) |d| d.onRecv(buf);
        }
        self.armRecv();
    }

    fn armRecv(self: *NamedSocket) void {
        if (self.state != .open) return;

        self.io.recv(
            *NamedSocket,
            self,
            onRecv,
            &self.recv_completion,
            self.socket.?,
            self.recv_buf.?.writable(),
        );
        self.incrementPendingOps();
    }

    fn finalize(self: *NamedSocket) void {
        if (self.recv_buf) |buf| {
            buf.unref();
            self.recv_buf = null;
        }
        self.buffer_pool.deinit();
        self.allocator.destroy(self);
    }

    // inline helpers so he dont have this check spread everywhere we use them
    inline fn incrementPendingOps(self: *NamedSocket) void {
        if (self.io_supports_cancellation) self.pending_ops += 1;
    }

    inline fn decrementPendingOps(self: *NamedSocket) void {
        if (self.io_supports_cancellation) self.pending_ops -= 1;
    }
};

const ServerConnectionState = enum {
    init,
    opening,
    open,
    listening,
    closing,
    closed,
};

pub const NamedServerSocket = struct {
    allocator: std.mem.Allocator,
    delegate: *NamedServerSocketDelegate,
    io: *IO,
    socket: std.posix.fd_t,
    path: []const u8,
    state: ServerConnectionState,
    accept_completion: IO.Completion,

    pub fn create(allocator: std.mem.Allocator, delegate: *NamedServerSocketDelegate, io: *IO, path: []const u8) !NamedServerSocket {
        const socket = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(socket);

        // unlink in case it was serving at the same path before
        std.posix.unlink(path) catch {};

        return .{
            .allocator = allocator,
            .delegate = delegate,
            .io = io,
            .socket = socket,
            .path = path,
            .state = .open,
            .accept_completion = undefined,
        };
    }

    pub fn deinit(self: *NamedServerSocket) void {
        self.close();
    }

    pub fn close(self: *NamedServerSocket) void {
        if (self.state == .closed) return;

        std.posix.close(self.socket);
        self.state = .closed;
        self.delegate.onClose();
    }

    pub fn listen(self: *NamedServerSocket) !void {
        // bind to path
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);

        const path_len = @min(self.path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.path[0..path_len]);

        try std.posix.bind(self.socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(self.socket, 16);
        self.state = .listening;
        try self.armAccept();
    }

    fn armAccept(self: *NamedServerSocket) !void {
        self.io.accept(
            *NamedServerSocket,
            self,
            onAccept,
            &self.accept_completion,
            self.socket,
        );
    }

    fn onAccept(self: *NamedServerSocket, _: *IO.Completion, result: IO.AcceptError!std.posix.fd_t) void {
        const client_fd = result catch |err| {
            std.log.err("NamedServerSocket onAccept: failed getting the accepted socket", .{});
            if (err == error.Canceled) return;
            self.armAccept() catch {
                std.log.err("NamedServerSocket IO.accept: failed to schedule accept", .{});
                return;
            };
            return;
        };
        const conn = NamedSocket.init(self.allocator, self.io);
        conn.accept(client_fd);
        // the delegate is responsible for the NamedSocket ownership/cleanup
        self.delegate.onAccept(conn);

        self.armAccept() catch {
            std.log.err("NamedServerSocket IO.accept: failed to schedule accept", .{});
            return;
        };
    }
};

pub const NamedSocketDelegate = struct {
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

    pub fn onConnection(self: NamedSocketDelegate) void {
        self.vtable.onConnection(self.ptr);
    }

    pub fn onConnectionFailed(self: NamedSocketDelegate, err: IO.ConnectError) void {
        self.vtable.onConnectionFailed(self.ptr, err);
    }

    pub fn onDisconnect(self: NamedSocketDelegate) void {
        self.vtable.onDisconnect(self.ptr);
    }

    pub fn onClose(self: NamedSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onRecv(self: NamedSocketDelegate, buffer: *IOBuffer) void {
        self.vtable.onRecv(self.ptr, buffer);
    }

    pub fn onRecvFailed(self: NamedSocketDelegate, err: IO.RecvError) void {
        self.vtable.onRecvFailed(self.ptr, err);
    }

    pub fn onSend(self: NamedSocketDelegate, sent: usize) void {
        self.vtable.onSend(self.ptr, sent);
    }

    pub fn onSendFailed(self: NamedSocketDelegate, err: IO.SendError) void {
        self.vtable.onSendFailed(self.ptr, err);
    }
};

pub const NamedServerSocketDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onClose: *const fn (ptr: *anyopaque) void,
        onAccept: *const fn (ptr: *anyopaque, socket: *NamedSocket) void,
    };

    pub fn onClose(self: NamedServerSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onAccept(self: NamedServerSocketDelegate, socket: *NamedSocket) void {
        self.vtable.onAccept(self.ptr, socket);
    }
};

fn onDataCompletionLinux(ctx: ?*anyopaque, _: *IO.Completion, result: *const anyopaque) void {
    std.debug.print("OnDataCompletion: doing nothing here, just asserting it was called", .{});
    _ = ctx;
    _ = result;
}

fn onDataCompletionDarwin(_: *IO, _: *IO.Completion) void {
    std.debug.print("OnDataCompletion: doing nothing here, just asserting it was called", .{});
}

fn onConnectCompletion(ctx: ?*anyopaque, _: *IO.Completion, result: *const anyopaque) void {
    std.debug.print("OnConnectCompletion: doing nothing here, just asserting it was called", .{});
    _ = ctx;
    _ = result;
}
