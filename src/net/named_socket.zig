const std = @import("std");
const builtin = @import("builtin");
const io_file = if (builtin.os.tag == .linux) @import("../io/linux.zig") else @import("../io/darwin.zig");
const IO = io_file.IO;

const ConnectionState = enum {
    open,
    closing,
    closed,
};

pub const NamedSocketConnection = struct {
    allocator: std.mem.Allocator,
    delegate: ?*NamedSocketDelegate,
    io: *IO,
    socket: std.posix.fd_t,
    recv_completion: IO.Completion,
    cancel_completion: IO.Completion,
    // FIXME: replace this with an IOBuffer /net/io_buffer.zig
    buf: [4096]u8,
    state: ConnectionState,
    pending_ops: u8,
    closed_request: bool,

    pub fn init(self: *NamedSocketConnection, allocator: std.mem.Allocator, io: *IO, socket: std.posix.fd_t) void {
        self.allocator = allocator;
        self.delegate = null;
        self.io = io;
        self.socket = socket;
        self.state = .open;
        self.pending_ops = 0;
        self.closed_request = false;
        if (builtin.os.tag == .linux) {
            self.recv_completion = .{
                .io = io,
                .operation = .{
                    .recv = .{
                        .socket = self.socket,
                        .buffer = &self.buf,
                    },
                },
                .context = self,
                .callback = onDataCompletionLinux,
            };
        } else if (builtin.os.tag == .macos) {
            self.recv_completion = .{
                .operation = .{
                    .recv = .{
                        .socket = self.socket,
                        .buffer = &self.buf,
                        .len = self.buf.len,
                    },
                },
                .context = self,
                .callback = onDataCompletionDarwin,
            };
        }
    }

    pub fn deinit(self: *NamedSocketConnection) void {
        self.close();
        self.allocator.destroy(self);
    }

    pub fn setDelegate(self: *NamedSocketConnection, delegate: *NamedSocketDelegate) void {
        self.delegate = delegate;
        // arm the first recv as now we have a delegate to call back
        self.armRecv();
    }

    pub fn close(self: *NamedSocketConnection) void {
        if (self.closed_request) return;

        self.closed_request = true;
        self.state = .closing;

        if (comptime builtin.os.tag == .macos) {
            // reset it before calling as is meaningless in the mac os case
            self.pending_ops = 0;
            self.tryFinalize();
        } else {
            self.io.cancel(
                *NamedSocketConnection,
                self,
                onCancelComplete,
                .{
                    .completion = &self.cancel_completion,
                    .target = &self.recv_completion,
                },
            );
            self.pending_ops += 1;
        }
    }

    fn tryFinalize(self: *NamedSocketConnection) void {
        if (self.pending_ops != 0) return;
        if (self.state == .closed) return;
        self.state = .closed;
        if (comptime builtin.os.tag == .macos) {
            self.io.close_socket(self.socket);
        } else {
            std.posix.close(self.socket);
        }
        if (self.delegate) |d| d.onClose();
    }

    fn onCancelComplete(self: *NamedSocketConnection, _: *IO.Completion, _: IO.CancelError!void) void {
        self.pending_ops -= 1;
        self.tryFinalize();
    }

    fn onRecv(self: *NamedSocketConnection, _: *IO.Completion, result: IO.RecvError!usize) void {
        self.pending_ops -= 1;
        if (self.state == .closing) {
            self.tryFinalize();
            return;
        }
        const n = result catch {
            self.close();
            return;
        };
        if (n == 0) {
            // connection is gone
            self.close();
            return;
        }
        if (self.delegate) |d| d.onRecv(self.buf[0..n]);
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
        self.pending_ops += 1;
    }

    fn onDataCompletionLinux(ctx: ?*anyopaque, _: *IO.Completion, result: *const anyopaque) void {
        std.debug.print("NamedProcessChannel.OnDataCompletion: doing nothing here, just asserting it was called", .{});
        _ = ctx;
        _ = result;
    }

    fn onDataCompletionDarwin(_: *IO, _: *IO.Completion) void {
        std.debug.print("NamedProcessChannel.OnDataCompletion: doing nothing here, just asserting it was called", .{});
    }
};

pub const NamedServerSocketConnection = struct {
    allocator: std.mem.Allocator,
    delegate: *NamedServerSocketDelegate,
    io: *IO,
    socket: std.posix.fd_t,
    path: []const u8,
    closed: bool,
    accept_completion: IO.Completion,

    pub fn create(allocator: std.mem.Allocator, delegate: *NamedServerSocketDelegate, io: *IO, path: []const u8) !NamedServerSocketConnection {
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
            self.armAccept() catch {
                std.log.err("NamedServerSocketConnection IO.accept: failed to schedule accept", .{});
                return;
            };
            return;
        };
        const conn = self.allocator.create(NamedSocketConnection) catch return;
        conn.init(self.allocator, self.io, client_fd);
        // the delegate is responsible for the NamedSocketConnection ownership/cleanup
        self.delegate.onAccept(conn);

        self.armAccept() catch {
            std.log.err("NamedServerSocketConnection IO.accept: failed to schedule accept", .{});
            return;
        };
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
        onAccept: *const fn (ptr: *anyopaque, socket: *NamedSocketConnection) void,
    };

    pub fn onClose(self: NamedServerSocketDelegate) void {
        self.vtable.onClose(self.ptr);
    }

    pub fn onAccept(self: NamedServerSocketDelegate, socket: *NamedSocketConnection) void {
        self.vtable.onAccept(self.ptr, socket);
    }
};
