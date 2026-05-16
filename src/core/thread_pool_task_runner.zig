const std = @import("std");
const core = @import("core.zig");
const ThreadId = core.ThreadId;
const TaskRunner = core.TaskRunner;
const Task = core.Task;
const TaskQueue = core.TaskQueue;
const ThreadRegistry = core.ThreadRegistry;

pub const ThreadPoolTaskRunner = struct {
    registry: *ThreadRegistry,
    pool: std.Thread.Pool,
    runner: TaskRunner,

    pub fn init(self: *ThreadPoolTaskRunner, allocator: std.mem.Allocator, registry: *ThreadRegistry, nworkers: usize) !void {
        self.registry = registry;
        self.registry.set(.workers, self.task_runner());
        self.runner = .{
            .ptr = self,
            .vtable = &vtable,
        };
        try self.pool.init(.{
            .allocator = allocator,
            .n_jobs = nworkers,
        });
    }

    pub fn deinit(self: *ThreadPoolTaskRunner) void {
        self.pool.deinit();
    }

    pub fn postTask(self: *ThreadPoolTaskRunner, node: *TaskQueue.Node) void {
        self.pool.spawn(struct {
            fn run(task: *Task) void {
                task.callback(task);
            }
        }.run, .{node.value}) catch unreachable;
    }

    pub fn postDelayedTask(self: *ThreadPoolTaskRunner, delay_ns: u64, node: *TaskQueue.Node) void {
        self.pool.spawn(struct {
            fn run(task: *Task, ns: u64) void {
                std.Thread.sleep(ns);
                task.callback(task);
            }
        }.run, .{ node.value, delay_ns }) catch unreachable;
    }

    pub fn postTaskTo(self: *ThreadPoolTaskRunner, id: ThreadId, node: *TaskQueue.Node) void {
        self.registry.get(id).postTask(node);
    }

    pub fn task_runner(self: *ThreadPoolTaskRunner) *TaskRunner {
        return &self.runner;
    }

    const vtable = TaskRunner.VTable{
        .postTask = struct {
            fn f(ptr: *anyopaque, node: *TaskQueue.Node) void {
                const self: *ThreadPoolTaskRunner = @ptrCast(@alignCast(ptr));
                self.postTask(node);
            }
        }.f,
        .postDelayedTask = struct {
            fn f(ptr: *anyopaque, delay_ns: u64, node: *TaskQueue.Node) void {
                const self: *ThreadPoolTaskRunner = @ptrCast(@alignCast(ptr));
                self.postDelayedTask(delay_ns, node);
            }
        }.f,
        .postTaskTo = struct {
            fn f(ptr: *anyopaque, id: ThreadId, node: *TaskQueue.Node) void {
                const self: *ThreadPoolTaskRunner = @ptrCast(@alignCast(ptr));
                self.postTaskTo(id, node);
            }
        }.f,
    };
};
