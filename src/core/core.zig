// Core shared interfaces
const work_queue = @import("work_queue.zig");
const run_loop = @import("run_loop.zig");
const task_runner = @import("task_runner.zig");
const thread_pool_task_runner = @import("thread_pool_task_runner.zig");
const single_thread_task_runner = @import("single_thread_task_runner.zig");
const thread_registry = @import("thread_registry.zig");

// A unique thread identifier
pub const ThreadId = enum {
    main,
    service,
    workers,
};

// A TaskRunner task
pub const Task = struct {
    callback: *const fn (task: *Task) void,
};

// exports
pub const TaskQueue = work_queue.WorkQueue(*Task);

// run loop
pub const RunLoop = run_loop.RunLoop;
pub const RunLoopDelegate = run_loop.RunLoopDelegate;
pub const ShutdownTask = run_loop.ShutdownTask;

// task runner
pub const TaskRunner = task_runner.TaskRunner;
pub const SingleThreadTaskRunner = single_thread_task_runner.SingleThreadTaskRunner;
pub const ThreadPoolTaskRunner = thread_pool_task_runner.ThreadPoolTaskRunner;
pub const ThreadRegistry = thread_registry.ThreadRegistry;
