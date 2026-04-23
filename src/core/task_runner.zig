const base = @import("base.zig");
const ThreadId = base.ThreadId;
const Task = base.Task;
const TaskQueue = base.TaskQueue;

pub const TaskRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        postTask: *const fn (ptr: *anyopaque, node: *TaskQueue.Node) void,
        postDelayedTask: *const fn (ptr: *anyopaque, delay_ns: u64, node: *TaskQueue.Node) void,
        postTaskTo: *const fn (ptr: *anyopaque, id: ThreadId, node: *TaskQueue.Node) void,
    };

    pub fn postTask(self: TaskRunner, node: *TaskQueue.Node) void {
        self.vtable.postTask(self.ptr, node);
    }

    pub fn postDelayedTask(self: TaskRunner, delay_ns: u64, node: *TaskQueue.Node) void {
        self.vtable.postDelayedTask(self.ptr, delay_ns, node);
    }

    pub fn postTaskTo(self: TaskRunner, id: ThreadId, node: *TaskQueue.Node) void {
        self.vtable.postTaskTo(self.ptr, id, node);
    }
};
