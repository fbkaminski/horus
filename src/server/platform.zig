const std = @import("std");
const base = @import("../core/base.zig");
const thread = @import("../core/single_thread_task_runner.zig");
const thread_pool = @import("../core/thread_pool_task_runner.zig");
const task_runner = @import("../core/task_runner.zig");
const run_loop_file = @import("../core/run_loop.zig");
const thread_registry_file = @import("../core/thread_registry.zig");
const service_manager = @import("service_manager.zig");
const SingleThreadTaskRunner = thread.SingleThreadTaskRunner;
const ThreadPoolTaskRunner = thread_pool.ThreadPoolTaskRunner;
const ServiceManager = service_manager.ServiceManager;
const TaskRunner = task_runner.TaskRunner;
const ThreadRegistry = thread_registry_file.ThreadRegistry;
const RunLoop = run_loop_file.RunLoop;
const RunLoopDelegate = run_loop_file.RunLoopDelegate;

pub const Platform = struct {
    allocator: std.mem.Allocator,
    thread_registry: ThreadRegistry,
    main_task_runner: SingleThreadTaskRunner,
    workers_task_runner: ThreadPoolTaskRunner,
    service_manager: ServiceManager,
    runloop: RunLoop,

    pub fn init(allocator: std.mem.Allocator) !*Platform {
        const self = try allocator.create(Platform);
        self.allocator = allocator;
        self.thread_registry = ThreadRegistry.init();

        try self.main_task_runner.init(allocator, &self.thread_registry, .main);
        try self.workers_task_runner.init(allocator, &self.thread_registry, 4);

        try self.service_manager.init(self.allocator, &self.thread_registry);

        self.runloop = RunLoop.init(self.main_task_runner.runloop_delegate());

        return self;
    }

    pub fn deinit(self: *Platform) void {
        self.service_manager.shutdown();
        self.workers_task_runner.deinit();
        self.service_manager.deinit();
        self.main_task_runner.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Platform) !void {
        // start the service manager
        try self.service_manager.spawn();

        //const quit_closure = try self.runloop.quitClosure(self.allocator);
        //self.main_task_runner.postDelayedTask(5000 * std.time.ns_per_ms, &quit_closure.node);
        // run the main thread
        self.runloop.run();
    }
};
