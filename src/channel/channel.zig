//
const std = @import("std");
const frame_file = @import("frame.zig");
const Frame = frame_file.Frame;

pub const ChannelMode = enum {
    SERVER,
    CLIENT,
};

pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mode: *const fn (ptr: *anyopaque) ChannelMode,
        // client only
        //connect: *fn (ptr: *anyopaque) void,
        send: *const fn (ptr: *anyopaque, frame: *Frame) void,
        upgrade: *const fn (ptr: *anyopaque) void,
        flush: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn mode(self: Channel) ChannelMode {
        return self.vtable.mode(self.vtable);
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
