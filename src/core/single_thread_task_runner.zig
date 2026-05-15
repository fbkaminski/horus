const std = @import("std");
const builtin = @import("builtin");
const base = @import("base.zig");
const task_runner_file = @import("task_runner.zig");
const runloop = @import("run_loop.zig");
const thread_registry_file = @import("thread_registry.zig");
const io_buffer = @import("../net/io_buffer.zig");
const IO = @import("../io/io.zig").IO;
const TaskQueue = base.TaskQueue;
const Task = base.Task;
const TaskRunner = task_runner_file.TaskRunner;
const ThreadRegistry = thread_registry_file.ThreadRegistry;
const ThreadId = base.ThreadId;
const RunLoopDelegate = runloop.RunLoopDelegate;
const IOBufferPool = io_buffer.IOBufferPool;

threadlocal var current_task_runner: ?*SingleThreadTaskRunner = undefined;

pub const SingleThreadTaskRunner = struct {
    allocator: std.mem.Allocator,
    pool: IOBufferPool,
    handle: ?std.Thread = null,
    entry: Entry,
    registry: *ThreadRegistry,
    io: IO,
    running: std.atomic.Value(bool),
    id: std.Thread.Id = undefined,
    thread_type: ThreadId,
    queue: TaskQueue,
    wake_event: IO.Event,
    wake_completion: IO.Completion,
    wake_buf: u64 = 0,
    runner: TaskRunner,
    delegate: RunLoopDelegate,
    is_main: bool,
    spawned: bool,

    const Entry = struct {
        task_runner: *SingleThreadTaskRunner,
        ptr: *anyopaque,
        run_fn: *const fn (ptr: *anyopaque) anyerror!void,
    };

    pub fn init(self: *SingleThreadTaskRunner, allocator: std.mem.Allocator, registry: *ThreadRegistry, thread_type: ThreadId) !void {
        self.is_main = thread_type == .main;
        self.spawned = false;
        self.pool = IOBufferPool.init(allocator, .{});
        self.allocator = allocator;
        self.registry = registry;
        self.entry = .{
            .task_runner = self,
            .ptr = undefined,
            .run_fn = undefined,
        };
        self.io = try IO.init(256, 0);
        self.running = .{ .raw = false };
        self.thread_type = thread_type;
        self.queue = .{};
        self.wake_event = try self.io.open_event();
        self.wake_completion = undefined;
        self.wake_buf = 0;
        self.runner = .{
            .ptr = self,
            .vtable = &vtable,
        };
        self.delegate = .{
            .ptr = self,
            .vtable = &runloop_delegate_vtable,
        };

        // register this task runner in the thread registry
        registry.set(thread_type, self.task_runner());

        if (self.is_main) {
            self.enterThread();
        }
    }

    pub fn deinit(self: *SingleThreadTaskRunner) void {
        if (self.is_main) {
            self.exitThread();
        }
        if (comptime builtin.os.tag == .linux) {
            std.posix.close(self.wake_event);
        }
        self.pool.deinit();
    }

    pub fn isCurrentThread(self: *SingleThreadTaskRunner) bool {
        return std.Thread.getCurrentId() == self.id;
    }

    pub fn start(
        self: *SingleThreadTaskRunner,
        comptime run_fn: anytype,
        context: anytype,
    ) !void {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn run(ptr: *anyopaque) anyerror!void {
                const ctx: Context = @ptrCast(@alignCast(ptr));
                try run_fn(ctx);
            }
        };

        self.entry.task_runner = self;
        self.entry.ptr = context;
        self.entry.run_fn = wrapper.run;

        self.handle = try std.Thread.spawn(.{}, threadEntry, .{self.entry});
        self.spawned = true;
    }

    pub fn run(self: *SingleThreadTaskRunner) !void {
        while (self.running.load(.acquire)) {
            try self.io.run_for_ns(10 * std.time.ns_per_ms);
        }
    }

    pub fn runOnce(self: *SingleThreadTaskRunner, timeout: u64) !void {
        try self.io.run_for_ns(@intCast(timeout));
    }

    pub fn stop(self: *SingleThreadTaskRunner) void {
        self.running.store(false, .release);
        self.wake();
        if (self.spawned) {
            self.handle.?.join();
        }
    }

    pub fn postTask(self: *SingleThreadTaskRunner, node: *TaskQueue.Node) void {
        self.queue.push(node);
        self.wake();
    }

    pub fn postDelayedTask(self: *SingleThreadTaskRunner, delay_ns: u64, node: *TaskQueue.Node) void {
        var timeout_completion = self.allocator.create(DelayedTaskCompletion) catch {
            return;
        };
        timeout_completion.node = node;
        self.io.timeout(
            *SingleThreadTaskRunner,
            self,
            struct {
                fn onTimeout(runner: *SingleThreadTaskRunner, c: *IO.Completion, result: IO.TimeoutError!void) void {
                    _ = result catch {}; // ignore cancellation
                    const d: *DelayedTaskCompletion = @fieldParentPtr("completion", c);
                    runner.postTask(d.node);
                    runner.allocator.destroy(d);
                }
            }.onTimeout,
            &timeout_completion.completion,
            @intCast(delay_ns),
        );
    }

    pub fn postTaskTo(self: *SingleThreadTaskRunner, id: ThreadId, node: *TaskQueue.Node) void {
        self.registry.get(id).postTask(node);
    }

    pub fn task_runner(self: *SingleThreadTaskRunner) *TaskRunner {
        return &self.runner;
    }

    pub fn runloop_delegate(self: *SingleThreadTaskRunner) *RunLoopDelegate {
        return &self.delegate;
    }

    pub fn wake(self: *SingleThreadTaskRunner) void {
        self.io.event_trigger(self.wake_event, &self.wake_completion);
    }
    fn onWake(completion: *IO.Completion) void {
        const self: *SingleThreadTaskRunner = @fieldParentPtr("wake_completion", completion);
        // Re-arm for next wakeup before draining tasks
        self.armWake();
        self.drain();
    }

    fn drain(self: *SingleThreadTaskRunner) void {
        while (self.queue.pop()) |node| {
            const task: *Task = node.value;
            task.callback(task);
        }
    }

    fn armWake(self: *SingleThreadTaskRunner) void {
        std.debug.assert(self.isCurrentThread());
        self.io.event_listen(self.wake_event, &self.wake_completion, onWake);
    }

    fn enterThread(self: *SingleThreadTaskRunner) void {
        self.id = std.Thread.getCurrentId();
        self.armWake();
        self.running.store(true, .release);
        current_task_runner = self;
    }

    fn exitThread(self: *SingleThreadTaskRunner) void {
        self.io.deinit();
        current_task_runner = null;
    }

    fn threadEntry(entry: Entry) void {
        entry.task_runner.enterThread();
        entry.run_fn(entry.ptr) catch |err| {
            std.log.err("task runner error: {}", .{err});
        };
        entry.task_runner.exitThread();
    }

    const vtable = TaskRunner.VTable{
        .postTask = struct {
            fn f(ptr: *anyopaque, node: *TaskQueue.Node) void {
                const self: *SingleThreadTaskRunner = @ptrCast(@alignCast(ptr));
                self.postTask(node);
            }
        }.f,
        .postDelayedTask = struct {
            fn f(ptr: *anyopaque, delay_ns: u64, node: *TaskQueue.Node) void {
                const self: *SingleThreadTaskRunner = @ptrCast(@alignCast(ptr));
                self.postDelayedTask(delay_ns, node);
            }
        }.f,
        .postTaskTo = struct {
            fn f(ptr: *anyopaque, id: ThreadId, node: *TaskQueue.Node) void {
                const self: *SingleThreadTaskRunner = @ptrCast(@alignCast(ptr));
                self.postTaskTo(id, node);
            }
        }.f,
    };

    const runloop_delegate_vtable = RunLoopDelegate.VTable{
        .run = struct {
            fn f(ptr: *anyopaque, timeout: u64) void {
                const self: *SingleThreadTaskRunner = @ptrCast(@alignCast(ptr));
                self.runOnce(timeout) catch |err| std.log.err("run: {}", .{err});
            }
        }.f,
        .quit = struct {
            fn f(ptr: *anyopaque) void {
                const self: *SingleThreadTaskRunner = @ptrCast(@alignCast(ptr));
                self.stop();
            }
        }.f,
    };
};

const DelayedTaskCompletion = struct {
    completion: IO.Completion = undefined,
    node: *TaskQueue.Node,
};
