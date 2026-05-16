//
const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net/net.zig");
const frame_file = @import("frame.zig");
const ipc_channel = @import("ipc_channel.zig");

// exports
pub const Frame = frame_file.Frame;
pub const IpcChannel = ipc_channel.IpcChannel;
pub const IpcServerChannel = ipc_channel.IpcServerChannel;

// FIXME: the IO layer shouldnt leak here
//        its here for the error messages
// TODO:  create internal error messages
const IO = @import("../io/io.zig").IO;
const IOBuffer = net.IOBuffer;

pub const ChannelMode = enum {
    SERVER,
    CLIENT,
};

pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mode: *const fn (ptr: *anyopaque) ChannelMode,
        send: *const fn (ptr: *anyopaque, frame: *Frame) void,
        upgrade: *const fn (ptr: *anyopaque) void,
        flush: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn mode(self: Channel) ChannelMode {
        return self.vtable.mode(self.ptr);
    }

    pub fn send(self: Channel, frame: *Frame) void {
        self.vtable.send(self.ptr, frame);
    }

    // upgrade to shared memory todo: design properly
    pub fn upgrade(self: Channel) void {
        self.vtable.upgrade(self.ptr);
    }

    pub fn flush(self: Channel) void {
        self.vtable.flush(self.ptr);
    }

    pub fn close(self: Channel) void {
        self.vtable.close(self.ptr);
    }
};

pub const ChannelListener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mode: *const fn (ptr: *anyopaque) ChannelMode,
        close: *const fn (ptr: *anyopaque) void,
        listen: *const fn (ptr: *anyopaque, path: []const u8) void,
    };

    pub fn listen(self: ChannelListener) void {
        self.vtable.listen(self.ptr);
    }

    pub fn mode(self: Channel) ChannelMode {
        return self.vtable.mode(self.ptr);
    }

    pub fn close(self: Channel) void {
        self.vtable.close(self.ptr);
    }
};

pub const ChannelListenerDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onConnection: *const fn (ptr: *anyopaque, server: *ChannelListener, client: *Channel) void,
        onClose: *const fn (ptr: *anyopaque, server: *ChannelListener) void,
    };

    pub fn onConnection(self: ChannelListenerDelegate, server: *ChannelListener, client: *Channel) void {
        self.vtable.onConnection(self.ptr, server, client);
    }

    pub fn onClose(self: ChannelListenerDelegate, server: *ChannelListener) void {
        self.vtable.onClose(self.ptr, server);
    }
};

pub const ChannelDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onConnection: *const fn (ptr: *anyopaque, client: *Channel) void,
        onConnectionFailed: *const fn (ptr: *anyopaque, client: *Channel, err: IO.ConnectError) void,
        onDisconnect: *const fn (ptr: *anyopaque, client: *Channel) void,
        onConnectionClosed: *const fn (ptr: *anyopaque, client: *Channel) void,
        onReceive: *const fn (ptr: *anyopaque, client: *Channel, buffer: *IOBuffer) void,
        onReceiveFailed: *const fn (ptr: *anyopaque, client: *Channel, err: IO.RecvError) void,
        onSend: *const fn (ptr: *anyopaque, client: *Channel, sent: usize) void,
        onSendFailed: *const fn (ptr: *anyopaque, client: *Channel, err: IO.SendError) void,
    };

    pub fn onConnection(self: ChannelDelegate, client: *Channel) void {
        self.vtable.onConnection(self.ptr, client);
    }

    pub fn onConnectionFailed(self: ChannelDelegate, client: *Channel, err: IO.ConnectError) void {
        self.vtable.onConnectionFailed(self.ptr, client, err);
    }

    pub fn onDisconnect(self: ChannelDelegate, client: *Channel) void {
        self.vtable.onDisconnect(self.ptr, client);
    }

    pub fn onConnectionClosed(self: ChannelDelegate, client: *Channel) void {
        self.vtable.onConnectionClosed(self.ptr, client);
    }

    pub fn onReceive(self: ChannelDelegate, client: *Channel, buffer: *IOBuffer) void {
        self.vtable.onReceive(self.ptr, client, buffer);
    }

    pub fn onReceiveFailed(self: ChannelDelegate, client: *Channel, err: IO.RecvError) void {
        self.vtable.onReceiveFailed(self.ptr, client, err);
    }

    pub fn onSend(self: ChannelDelegate, client: *Channel, sent: usize) void {
        self.vtable.onSend(self.ptr, client, sent);
    }

    pub fn onSendFailed(self: ChannelDelegate, client: *Channel, err: IO.SendError) void {
        self.vtable.onSendFailed(self.ptr, client, err);
    }
};
