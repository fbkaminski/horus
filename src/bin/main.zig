const std = @import("std");
const os = std.os;
const log = std.log.scoped(.timer_test);
const horus = @import("horus");

//const MessageLoop = dht.MessageLoop;
//const RunLoop = dht.RunLoop;

const Platform = horus.Platform;

// pub fn main() !void {
//     const allocator = std.heap.page_allocator;
//     var loop = try MessageLoop.init(allocator);
//     defer loop.deinit();

//     var run_loop = RunLoop.init(&loop);

//     // // Bootstrap: post initial work before entering the loop
//     // loop.postTask(kademlia.startBootstrap, &dht);

//     // // Schedule a periodic bucket refresh every 15 minutes
//     // loop.postDelayedTask(15 * std.time.ns_per_min, kademlia.refreshBuckets, &dht);

//     // Graceful shutdown on SIGINT — post the quit closure as a task
//     const stop = run_loop.quitClosure();
//     //std.signals.onSigint(stop.callback, stop.ctx);

//     // Block here until quit fires
//     run_loop.run();
// }

// // Shared context passed through the task chain
// const PingPongCtx = struct {
//     loop: *MessageLoop,
//     run_loop: *RunLoop,
//     count: u32,
//     max: u32,
//     fired_at: [8]u64, // record actual fire times for validation
// };

// fn onTick(ctx: ?*anyopaque) void {
//     const c: *PingPongCtx = @ptrCast(@alignCast(ctx));

//     const now = dht.util.nanotime();
//     c.fired_at[c.count] = now;
//     log.info("tick {d}/{d}", .{ c.count + 1, c.max });

//     c.count += 1;
//     if (c.count >= c.max) {
//         log.info("all ticks fired, quitting", .{});
//         c.run_loop.quit();
//         return;
//     }

//     // Schedule the next tick 200ms from now
//     c.loop.postDelayedTask(200 * std.time.ns_per_ms, onTick, c);
// }

// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const alloc = gpa.allocator();

//     var loop = try MessageLoop.init(alloc);
//     defer loop.deinit();

//     var run_loop = RunLoop.init(loop);

//     var ctx = PingPongCtx{
//         .loop = loop,
//         .run_loop = &run_loop,
//         .count = 0,
//         .max = 5,
//         .fired_at = std.mem.zeroes([8]u64),
//     };

//     // Kick off the first tick immediately
//     loop.postTask(onTick, &ctx);

//     const start = dht.util.nanotime();
//     run_loop.run();
//     const elapsed = dht.util.nanotime() - start;

//     // Validate: 5 ticks at ~200ms each = ~800ms total (first fires immediately)
//     log.info("total elapsed: {d}ms", .{elapsed / std.time.ns_per_ms});
//     try std.testing.expect(ctx.count == ctx.max);

//     // Each tick after the first should be ~200ms after the previous
//     for (1..ctx.max) |i| {
//         const delta = ctx.fired_at[i] - ctx.fired_at[i - 1];
//         const delta_ms = delta / std.time.ns_per_ms;
//         log.info("tick {d} delta: {d}ms", .{ i, delta_ms });
//         // Allow 20ms slop for scheduler jitter
//         try std.testing.expect(delta_ms >= 180 and delta_ms <= 220);
//     }
// }

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var platform = try Platform.init(alloc);
    try platform.run();

    defer platform.deinit();
}
