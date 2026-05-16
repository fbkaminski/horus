const std = @import("std");
const builtin = @import("builtin");
const net_file = @import("net.zig");
const Socket = net_file.Socket;
const SocketConnectionArgs = net_file.SocketConnectionArgs;
const ServerSocketListenArgs = net_file.ServerSocketListenArgs;
const ServerSocket = net_file.ServerSocket;
const SocketDelegate = net_file.SocketDelegate;
const ServerSocketDelegate = net_file.ServerSocketDelegate;
const SocketState = net_file.SocketState;
const ServerSocketState = net_file.ServerSocketState;
const IO = @import("../io/io.zig").IO;
const IOBuffer = net_file.IOBuffer;
const IOBufferPool = net_file.IOBufferPool;

pub const NamedSocket = struct {
    base: Socket,
    allocator: std.mem.Allocator,
    delegate: ?*SocketDelegate,
    io: *IO,
    socket: ?std.posix.fd_t,
    recv_completion: IO.Completion,
    cancel_completion: IO.Completion,
    connect_completion: IO.Completion,
    write_completion: IO.Completion,
    buffer_pool: *IOBufferPool,
    recv_buf: *IOBuffer,
    write_buf: ?*IOBuffer,
    state: SocketState,
    pending_ops: u8,
    // whether the io backend supports cancelation
    io_supports_cancellation: bool,

    pub fn init(self: *NamedSocket, allocator: std.mem.Allocator, io: *IO, buffer_pool: *IOBufferPool) void {
        //var self = allocator.create(NamedSocket) catch return undefined;
        self.allocator = allocator;
        self.delegate = null;
        self.io = io;
        self.socket = null;
        self.write_buf = null;
        self.recv_buf = buffer_pool.acquire() catch return undefined;
        self.state = .init;
        self.buffer_pool = buffer_pool;
        self.pending_ops = 0;
        if (builtin.os.tag == .linux) {
            self.io_supports_cancellation = true;
        } else if (builtin.os.tag == .macos) {
            self.io_supports_cancellation = false;
        }
        self.base = .{
            .ptr = self,
            .vtable = &socket_vtable,
        };
    }

    pub fn connect(self: *NamedSocket, args: SocketConnectionArgs) void {
        self.state = .opening;
        const address = std.net.Address.initUnix(args.path) catch return;
        const sock = std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            0,
        ) catch return;
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

    pub fn setDelegate(self: *NamedSocket, delegate: ?*SocketDelegate) void {
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
        self.recv_buf.advance_write(n);
        const cloned = self.buffer_pool.acquire() catch return;
        self.recv_buf.copy(cloned);
        if (self.delegate) |d| d.onRecv(cloned);
        self.armRecv();
    }

    fn armRecv(self: *NamedSocket) void {
        if (self.state != .open) return;

        self.recv_buf.write_pos = 0;

        self.io.recv(
            *NamedSocket,
            self,
            onRecv,
            &self.recv_completion,
            self.socket.?,
            self.recv_buf.writable(),
        );
        self.incrementPendingOps();
    }

    fn finalize(self: *NamedSocket) void {
        self.recv_buf.unref();
        self.allocator.destroy(self);
    }

    // inline helpers so he dont have this check spread everywhere we use them
    inline fn incrementPendingOps(self: *NamedSocket) void {
        if (self.io_supports_cancellation) self.pending_ops += 1;
    }

    inline fn decrementPendingOps(self: *NamedSocket) void {
        if (self.io_supports_cancellation) self.pending_ops -= 1;
    }

    const socket_vtable = Socket.VTable{
        .deinit = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.f,
        .setDelegate = struct {
            fn f(ptr: *anyopaque, delegate: ?*SocketDelegate) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.setDelegate(delegate);
            }
        }.f,
        .connect = struct {
            fn f(ptr: *anyopaque, args: SocketConnectionArgs) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.connect(args);
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
        .accept = struct {
            fn f(ptr: *anyopaque, socket: std.posix.fd_t) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.accept(socket);
            }
        }.f,
        .send = struct {
            fn f(ptr: *anyopaque, buffer: *IOBuffer) void {
                const self: *NamedSocket = @ptrCast(@alignCast(ptr));
                self.send(buffer);
            }
        }.f,
    };
};

pub const NamedServerSocket = struct {
    base: ServerSocket,
    allocator: std.mem.Allocator,
    delegate: *ServerSocketDelegate,
    io: *IO,
    pool: *IOBufferPool,
    socket: std.posix.fd_t,
    state: ServerSocketState,
    accept_completion: IO.Completion,

    pub fn init(self: *NamedServerSocket, allocator: std.mem.Allocator, delegate: *ServerSocketDelegate, io: *IO, pool: *IOBufferPool) void {
        const socket = std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        ) catch return;
        errdefer std.posix.close(socket);

        self.base = .{
            .ptr = self,
            .vtable = &socket_vtable,
        };
        self.allocator = allocator;
        self.delegate = delegate;
        self.io = io;
        self.pool = pool;
        self.socket = socket;
        self.state = .open;
        self.accept_completion = undefined;
    }

    pub fn deinit(self: *NamedServerSocket) void {
        self.close();
        self.allocator.destroy(self);
    }

    pub fn close(self: *NamedServerSocket) void {
        if (self.state == .closed) return;

        std.posix.close(self.socket);
        self.state = .closed;
        self.delegate.onClose();
    }

    pub fn listen(self: *NamedServerSocket, args: ServerSocketListenArgs) void {
        // unlink in case it was serving at the same path before
        std.posix.unlink(args.path) catch {};
        // bind to path
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);

        const path_len = @min(args.path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], args.path[0..path_len]);

        std.posix.bind(self.socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch return;
        std.posix.listen(self.socket, 16) catch return;
        self.state = .listening;
        self.armAccept();
    }

    fn armAccept(self: *NamedServerSocket) void {
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
            self.armAccept();
            return;
        };
        const conn: *NamedSocket = self.allocator.create(NamedSocket) catch return;
        conn.init(self.allocator, self.io, self.pool);
        conn.accept(client_fd);
        // the delegate is responsible for the NamedSocket ownership/cleanup
        self.delegate.onAccept(&conn.base);
        self.armAccept();
    }

    const socket_vtable = ServerSocket.VTable{
        .deinit = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedServerSocket = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.f,
        .listen = struct {
            fn f(ptr: *anyopaque, args: ServerSocketListenArgs) void {
                const self: *NamedServerSocket = @ptrCast(@alignCast(ptr));
                self.listen(args);
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NamedServerSocket = @ptrCast(@alignCast(ptr));
                self.close();
            }
        }.f,
    };
};

fn onDataCompletionLinux(ctx: ?*anyopaque, _: *IO.Completion, result: *const anyopaque) void {
    std.debug.print("OnDataCompletion: doing nothing here, just asserting it was called", .{});
    _ = ctx;
    _ = result;
}

fn onDataCompletionDarwin(_: *IO, _: *IO.Completion) void {
    std.debug.print("OnDataCompletion: doing nothing here, just asserting it was called", .{});
}
