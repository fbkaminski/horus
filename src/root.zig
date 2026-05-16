//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const builtin = @import("builtin");
// net
const net = @import("net/net.zig");
// core
const core = @import("core/core.zig");
// server
const server = @import("server/server.zig");

const io_file = @import("io/io.zig");

// dht
//const err = @import("dht/error.zig");
//const host = @import("dht/host.zig");
//const message = @import("dht/message.zig");
//const routing_table = @import("dht/routing_table.zig");

pub const IOBuffer = net.IOBuffer;
pub const IOBufferPool = net.IOBufferPool;
pub const NamedSocket = net.NamedSocket;
pub const SocketDelegate = net.SocketDelegate;
pub const SingleThreadTaskRunner = core.SingleThreadTaskRunner;
pub const RunLoop = core.RunLoop;
pub const ShutdownTask = core.ShutdownTask;

pub const Platform = server.Platform;
pub const ThreadRegistry = core.ThreadRegistry;
pub const Task = core.Task;
pub const TaskQueue = core.TaskQueue;
pub const IO = io_file.IO;
