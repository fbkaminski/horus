const std = @import("std");
const base = @import("../core/base.zig");
const Task = base.Task;
const TaskQueue = base.TaskQueue;

const timeout_ms = 10 * std.time.ns_per_ms;

pub const RunLoopDelegate = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, timeout: u64) void,
        quit: *const fn (ptr: *anyopaque) void,
    };

    pub fn run(self: RunLoopDelegate, timeout: u64) void {
        self.vtable.run(self.ptr, timeout);
    }

    pub fn quit(self: RunLoopDelegate) void {
        self.vtable.quit(self.ptr);
    }
};

pub const RunLoop = struct {
    delegate: *RunLoopDelegate,
    running: std.atomic.Value(bool),

    pub fn init(delegate: *RunLoopDelegate) RunLoop {
        return .{
            .delegate = delegate,
            .running = .{ .raw = true },
        };
    }

    pub fn run(self: *RunLoop) void {
        self.running.store(true, .release);
        while (self.running.load(.acquire)) {
            self.delegate.run(timeout_ms);
        }
        self.running.store(false, .release);
    }

    pub fn quit(self: *RunLoop) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
            self.delegate.quit();
        }
    }

    pub fn quitClosure(self: *RunLoop, allocator: std.mem.Allocator) !*ShutdownTask {
        var shutdown_task = try allocator.create(ShutdownTask);
        shutdown_task.task = .{
            .callback = ShutdownTask.callback,
        };
        shutdown_task.runloop = self;
        shutdown_task.allocator = allocator;
        shutdown_task.node.value = &shutdown_task.task;
        return shutdown_task;
    }
};

pub const ShutdownTask = struct {
    task: Task,
    node: TaskQueue.Node = .{ .value = undefined },
    allocator: std.mem.Allocator,
    runloop: *RunLoop,

    fn callback(task: *Task) void {
        const self: *ShutdownTask = @fieldParentPtr("task", task);
        std.log.info("shutting down", .{});
        self.runloop.quit();
        self.allocator.destroy(self);
    }
};
