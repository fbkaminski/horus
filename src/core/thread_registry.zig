const core = @import("core.zig");
const std = @import("std");
const ThreadId = core.ThreadId;
const TaskRunner = core.TaskRunner;

//
pub const ThreadRegistry = struct {
    task_runners: [@typeInfo(ThreadId).@"enum".fields.len]*TaskRunner,

    pub fn init() ThreadRegistry {
        return .{
            .task_runners = .{
                undefined,
                undefined,
                undefined,
            },
        };
    }

    pub fn set(self: *ThreadRegistry, id: ThreadId, task_runner: *TaskRunner) void {
        self.task_runners[@intFromEnum(id)] = task_runner;
    }

    pub fn get(self: *const ThreadRegistry, id: ThreadId) *TaskRunner {
        return self.task_runners[@intFromEnum(id)];
    }
};
