//
const std = @import("std");
const io_buffer = @import("../net/io_buffer.zig");
const frame_file = @import("frame.zig");
const Frame = frame_file.Frame;
const IOBuffer = io_buffer.IOBuffer;

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
        listen: *const fn (ptr: *anyopaque) void,
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
        onDataAvailable: *const fn (ptr: *anyopaque, client: *Channel, buffer: *IOBuffer) void,
        onConnectionClosed: *const fn (ptr: *anyopaque, client: *Channel) void,
    };

    pub fn onDataAvailable(self: ChannelDelegate, client: *Channel, buffer: *IOBuffer) void {
        self.vtable.onDataAvailable(self.ptr, client, buffer);
    }

    pub fn onConnectionClosed(self: ChannelDelegate, client: *Channel) void {
        self.vtable.onConnectionClosed(self.ptr, client);
    }
};
