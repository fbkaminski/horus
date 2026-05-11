const std = @import("std");
const horus = @import("horus");

const SingleThreadTaskRunner = horus.SingleThreadTaskRunner;
const RunLoop = horus.RunLoop;
const ThreadRegistry = horus.ThreadRegistry;
const NamedSocket = horus.NamedSocket;
const NamedSocketDelegate = horus.NamedSocketDelegate;
const IOBuffer = horus.IOBuffer;
const IOBufferPool = horus.IOBufferPool;
const Task = horus.Task;
const TaskQueue = horus.TaskQueue;
const ShutdownTask = horus.ShutdownTask;
const IO = horus.IO;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var thread_registry = ThreadRegistry.init();
    var main_thread: SingleThreadTaskRunner = undefined;

    try main_thread.init(alloc, &thread_registry, .main);

    defer main_thread.deinit();

    var runloop = RunLoop.init(main_thread.runloop_delegate());
    const quit_closure = try runloop.quitClosure(alloc);
    const ping_callback = try PingTask.init(alloc, &main_thread, quit_closure);

    // first ping on in 1 second
    main_thread.postDelayedTask(1000 * std.time.ns_per_ms, &ping_callback.node);

    runloop.run();

    ping_callback.deinit(alloc);
}

const MAX_PINGS = 4;

const PingTask = struct {
    allocator: std.mem.Allocator,
    task: Task,
    node: TaskQueue.Node = .{ .value = undefined },
    delegate: NamedSocketDelegate,
    socket: ?*NamedSocket,
    task_runner: *SingleThreadTaskRunner,
    shutdown_task: *ShutdownTask,
    state: State,
    pings: i32,
    buf: ?*IOBuffer,
    sbuf: [8]u8,

    const State = enum {
        init,
        connected,
        disconnected,
    };

    fn init(allocator: std.mem.Allocator, task_runner: *SingleThreadTaskRunner, shutdown_task: *ShutdownTask) !*PingTask {
        var ping_task = try allocator.create(PingTask);
        ping_task.allocator = allocator;
        ping_task.task = .{
            .callback = PingTask.callback,
        };
        ping_task.node.value = &ping_task.task;
        ping_task.task_runner = task_runner;
        ping_task.shutdown_task = shutdown_task;
        ping_task.state = .init;
        ping_task.pings = 0;
        ping_task.buf = null;
        ping_task.sbuf = undefined;
        ping_task.socket = null;

        ping_task.delegate = .{
            .ptr = ping_task,
            .vtable = &delegate_vtable,
        };

        return ping_task;
    }

    fn deinit(self: *PingTask, allocator: std.mem.Allocator) void {
        if (self.buf) |buf| {
            buf.unref();
            self.buf = null;
        }
        if (self.socket) |s| {
            s.setDelegate(null);
            s.deinit();
        }
        allocator.destroy(self);
    }

    fn callback(task: *Task) void {
        const self: *PingTask = @fieldParentPtr("task", task);
        if (self.state == .init) {
            self.connect();
            return;
        }
        self.send();
    }

    fn connect(self: *PingTask) void {
        std.log.info("connecting to /tmp/dht_host.sock..", .{});
        self.socket = NamedSocket.init(self.allocator, &self.task_runner.io);
        if (self.socket) |s| {
            s.setDelegate(&self.delegate);
            s.connect("/tmp/dht_host.sock") catch return;
        }
    }

    fn send(self: *PingTask) void {
        if (self.buf) |buf| {
            self.loadBuffer(buf);
            std.log.info("sending {s}", .{buf.readable()});
            if (self.socket) |s| s.send(buf);
        }
    }

    fn loadBuffer(self: *PingTask, buf: *IOBuffer) void {
        const message = if (self.pings < MAX_PINGS - 1) std.fmt.bufPrint(&self.sbuf, "PING {d}", .{self.pings + 1}) catch return else std.fmt.bufPrint(&self.sbuf, "SHUTDOWN", .{}) catch return;
        //const message = std.fmt.bufPrint(&self.sbuf, "PING {d}", .{self.pings + 1}) catch return;
        buf.write_pos = 0;
        var writer = std.io.Writer.fixed(buf.writable());
        _ = writer.writeAll(message) catch |err| {
            std.log.err("error writing to the buffer: {}", .{err});
        };
        buf.advance_write(message.len);
    }

    fn onConnection(self: *PingTask) void {
        self.state = .connected;
        self.buf = self.socket.?.buffer_pool.acquire() catch return;
        self.task_runner.postDelayedTask(2000 * std.time.ns_per_ms, &self.node);
    }

    fn onConnectionFailed(self: *PingTask, err: IO.ConnectError) void {
        std.log.info("PingTask.onConnectionFailed: {} => exiting now!", .{err});
        self.task_runner.postTask(&self.shutdown_task.node);
    }

    fn onDisconnect(self: *PingTask) void {
        _ = self;
        std.log.info("PingTask.onConnectionClosed: client connection disconnected by the remote peer.", .{});
    }

    fn onClose(self: *PingTask) void {
        std.log.info("PingTask.onConnectionClosed: client connection closed.", .{});
        _ = self;
    }

    fn onReceive(self: *PingTask, buffer: *IOBuffer) void {
        _ = self;
        std.log.info("received '{s}'", .{buffer.readable()});
        buffer.unref();
    }

    fn onReceiveFailed(self: *PingTask, err: IO.RecvError) void {
        _ = self;
        std.log.info("PingTask.onReceiveFailed: {}", .{err});
    }

    fn onSend(self: *PingTask, _: usize) void {
        self.pings += 1;
        if (self.pings < MAX_PINGS) {
            self.task_runner.postDelayedTask(300 * std.time.ns_per_ms, &self.node);
        } else {
            self.task_runner.postDelayedTask(300 * std.time.ns_per_ms, &self.shutdown_task.node);
        }
    }

    fn onSendFailed(self: *PingTask, err: IO.SendError) void {
        std.log.info("PingTask.onSendFailed: {} => exiting now!", .{err});
        self.task_runner.postTask(&self.shutdown_task.node);
    }

    const delegate_vtable = NamedSocketDelegate.VTable{
        .onConnection = struct {
            fn f(ptr: *anyopaque) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onConnection();
            }
        }.f,
        .onConnectionFailed = struct {
            fn f(ptr: *anyopaque, err: IO.ConnectError) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onConnectionFailed(err);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onClose();
            }
        }.f,
        .onDisconnect = struct {
            fn f(ptr: *anyopaque) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onDisconnect();
            }
        }.f,
        .onRecv = struct {
            fn f(ptr: *anyopaque, buffer: *IOBuffer) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onReceive(buffer);
            }
        }.f,
        .onRecvFailed = struct {
            fn f(ptr: *anyopaque, err: IO.RecvError) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onReceiveFailed(err);
            }
        }.f,
        .onSend = struct {
            fn f(ptr: *anyopaque, sent: usize) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onSend(sent);
            }
        }.f,
        .onSendFailed = struct {
            fn f(ptr: *anyopaque, err: IO.SendError) void {
                const self: *PingTask = @ptrCast(@alignCast(ptr));
                self.onSendFailed(err);
            }
        }.f,
    };
};
