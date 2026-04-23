// Core shared interfaces
const work_queue = @import("work_queue.zig");

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

pub const TaskQueue = work_queue.WorkQueue(*Task);
