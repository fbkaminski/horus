//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const builtin = @import("builtin");
// net
const socket = @import("net/socket.zig");
const named_socket = @import("net/named_socket.zig");
const io_buffer = @import("net/io_buffer.zig");
// core
const base = @import("core/base.zig");
const thread = @import("core/single_thread_task_runner.zig");
const run_loop = @import("core/run_loop.zig");
const thread_registry = @import("core/thread_registry.zig");

// platform
const platform = @import("server/platform.zig");

const io_file = if (builtin.os.tag == .linux) @import("io/linux.zig") else @import("io/darwin.zig");

// dht
//const err = @import("dht/error.zig");
//const host = @import("dht/host.zig");
//const message = @import("dht/message.zig");
//const routing_table = @import("dht/routing_table.zig");

pub const IOBuffer = io_buffer.IOBuffer;
pub const IOBufferPool = io_buffer.IOBufferPool;
pub const NamedSocket = named_socket.NamedSocket;
pub const SocketDelegate = socket.SocketDelegate;
pub const SingleThreadTaskRunner = thread.SingleThreadTaskRunner;
pub const RunLoop = run_loop.RunLoop;
pub const ShutdownTask = run_loop.ShutdownTask;

pub const Platform = platform.Platform;
pub const ThreadRegistry = thread_registry.ThreadRegistry;
pub const Task = base.Task;
pub const TaskQueue = base.TaskQueue;
pub const IO = io_file.IO;
