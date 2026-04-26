const std = @import("std");
const builtin = @import("builtin");
const cut_prefix = @import("common.zig").cut_prefix;

const os = std.os;
const posix = std.posix;
const system = posix.system;
const assert = std.debug.assert;
const is_darwin = builtin.target.os.tag.isDarwin();
const is_windows = builtin.target.os.tag == .windows;
const is_linux = builtin.target.os.tag == .linux;

/// Non-negative time difference between two `Instant`s.
pub const Duration = struct {
    ns: u64,

    pub fn us(amount_us: u64) Duration {
        return .{ .ns = amount_us * std.time.ns_per_us };
    }

    pub fn ms(amount_ms: u64) Duration {
        return .{ .ns = amount_ms * std.time.ns_per_ms };
    }

    pub fn seconds(amount_seconds: u64) Duration {
        return .{ .ns = amount_seconds * std.time.ns_per_s };
    }

    pub fn minutes(amount_minutes: u64) Duration {
        return .{ .ns = amount_minutes * std.time.ns_per_min };
    }

    // Duration in microseconds, μs, 1/1_000_000 of a second.
    pub fn to_us(duration: Duration) u64 {
        return @divFloor(duration.ns, std.time.ns_per_us);
    }

    // Duration in milliseconds, ms, 1/1_000 of a second.
    pub fn to_ms(duration: Duration) u64 {
        return @divFloor(duration.ns, std.time.ns_per_ms);
    }

    pub fn min(lhs: Duration, rhs: Duration) Duration {
        return .{ .ns = @min(lhs.ns, rhs.ns) };
    }

    pub fn max(lhs: Duration, rhs: Duration) Duration {
        return .{ .ns = @max(lhs.ns, rhs.ns) };
    }

    pub fn clamp(duration: Duration, clamp_min: Duration, clamp_max: Duration) Duration {
        assert(clamp_min.ns <= clamp_max.ns);
        if (duration.ns < clamp_min.ns) return clamp_min;
        if (duration.ns > clamp_max.ns) return clamp_max;
        return duration;
    }

    pub const sort = struct {
        pub fn asc(ctx: void, lhs: Duration, rhs: Duration) bool {
            return std.sort.asc(u64)(ctx, lhs.ns, rhs.ns);
        }
    };

    pub fn subtract(longer: Duration, shorter: Duration) Duration {
        assert(longer.ns >= shorter.ns);
        const difference_ns = longer.ns - shorter.ns;
        return .{ .ns = difference_ns };
    }

    // Human readable format like `1.123s`.
    // NB: this is a lossy operation, durations are rounded to look nice.
    pub fn format(
        duration: Duration,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.fmt.fmtDuration(duration.ns).format(fmt, options, writer);
    }

    pub fn parse_flag_value(
        string: []const u8,
        static_diagnostic: *?[]const u8,
    ) error{InvalidFlagValue}!Duration {
        assert(string.len > 0);
        var string_remaining = string;

        var result: Duration = .{ .ns = 0 };
        while (string_remaining.len > 0) {
            string_remaining, const component =
                try parse_flag_value_component(string_remaining, static_diagnostic);
            result.ns +|= component.ns;
        }

        if (result.ns >= 1_000 * std.time.ns_per_day) {
            static_diagnostic.* = "duration too large:";
            return error.InvalidFlagValue;
        }
        return result;
    }

    fn parse_flag_value_component(
        string: []const u8,
        static_diagnostic: *?[]const u8,
    ) error{InvalidFlagValue}!struct { []const u8, Duration } {
        const split_index = for (string, 0..) |c, index| {
            if (std.ascii.isDigit(c)) {
                // Numeric part continues.
            } else break index;
        } else {
            static_diagnostic.* = "missing unit; must be one of: d/h/m/s/ms/us/ns:";
            return error.InvalidFlagValue;
        };

        if (split_index == 0) {
            static_diagnostic.* = "missing value:";
            return error.InvalidFlagValue;
        }

        const string_amount = string[0..split_index];
        const string_remaining = string[split_index..];
        assert(string_amount.len > 0);
        assert(string_remaining.len > 0);

        const amount = std.fmt.parseInt(u64, string_amount, 10) catch |err| switch (err) {
            error.Overflow => {
                static_diagnostic.* = "integer overflow:";
                return error.InvalidFlagValue;
            },
            error.InvalidCharacter => unreachable,
        };

        const Unit = enum(u64) {
            ns = 1,
            us = std.time.ns_per_us,
            ms = std.time.ns_per_ms,
            s = std.time.ns_per_s,
            m = std.time.ns_per_min,
            h = std.time.ns_per_hour,
            d = std.time.ns_per_day,
        };

        inline for (comptime std.enums.values(Unit)) |unit| {
            if (cut_prefix(string_remaining, @tagName(unit))) |suffix| {
                return .{ suffix, .{ .ns = amount *| @intFromEnum(unit) } };
            }
        } else {
            static_diagnostic.* = "unknown unit; must be one of: d/h/m/s/ms/us/ns:";
            return error.InvalidFlagValue;
        }
    }
};

pub const Instant = struct {
    ns: u64,

    pub fn add(now: Instant, duration: Duration) Instant {
        return .{ .ns = now.ns + duration.ns };
    }

    pub fn duration_since(now: Instant, earlier: Instant) Duration {
        assert(now.ns >= earlier.ns);
        const elapsed_ns = now.ns - earlier.ns;
        return .{ .ns = elapsed_ns };
    }
};

pub const Time = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        monotonic: *const fn (*anyopaque) u64,
        realtime: *const fn (*anyopaque) i64,
        tick: *const fn (*anyopaque) void,
    };

    /// A timestamp to measure elapsed time, meaningful only on the same system, not across reboots.
    /// Always use a monotonic timestamp if the goal is to measure elapsed time.
    /// This clock is not affected by discontinuous jumps in the system time, for example if the
    /// system administrator manually changes the clock.
    pub fn monotonic(self: Time) Instant {
        return .{ .ns = self.vtable.monotonic(self.context) };
    }

    /// A timestamp to measure real (i.e. wall clock) time, meaningful across systems, and reboots.
    /// This clock is affected by discontinuous jumps in the system time.
    pub fn realtime(self: Time) i64 {
        return self.vtable.realtime(self.context);
    }

    pub fn tick(self: Time) void {
        self.vtable.tick(self.context);
    }
};

pub const TimeOS = struct {
    /// Hardware and/or software bugs can mean that the monotonic clock may regress.
    /// One example (of many): https://bugzilla.redhat.com/show_bug.cgi?id=448449
    /// We crash the process for safety if this ever happens, to protect against infinite loops.
    /// It's better to crash and come back with a valid monotonic clock than get stuck forever.
    monotonic_guard: u64 = 0,

    pub fn time(self: *TimeOS) Time {
        return .{
            .context = self,
            .vtable = &.{
                .monotonic = monotonic,
                .realtime = realtime,
                .tick = tick,
            },
        };
    }

    fn monotonic(context: *anyopaque) u64 {
        const self: *TimeOS = @ptrCast(@alignCast(context));

        const m = blk: {
            if (is_windows) break :blk monotonic_windows();
            if (is_darwin) break :blk monotonic_darwin();
            if (is_linux) break :blk monotonic_linux();
            @compileError("unsupported OS");
        };

        // "Oops!...I Did It Again"
        if (m < self.monotonic_guard) @panic("a hardware/kernel bug regressed the monotonic clock");
        self.monotonic_guard = m;
        return m;
    }

    fn monotonic_windows() u64 {
        assert(is_windows);
        // Uses QueryPerformanceCounter() on windows due to it being the highest precision timer
        // available while also accounting for time spent suspended by default:
        //
        // https://docs.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttime#remarks

        // QPF need not be globally cached either as it ends up being a load from read-only memory
        // mapped to all processed by the kernel called KUSER_SHARED_DATA (See "QpcFrequency")
        //
        // https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data
        // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
        const qpc = os.windows.QueryPerformanceCounter();
        const qpf = os.windows.QueryPerformanceFrequency();

        // 10Mhz (1 qpc tick every 100ns) is a common QPF on modern systems.
        // We can optimize towards this by converting to ns via a single multiply.
        //
        // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
        const common_qpf = 10_000_000;
        if (qpf == common_qpf) return qpc * (std.time.ns_per_s / common_qpf);

        // Convert qpc to nanos using fixed point to avoid expensive extra divs and
        // overflow.
        const scale = (std.time.ns_per_s << 32) / qpf;
        return @as(u64, @truncate((@as(u96, qpc) * scale) >> 32));
    }

    fn monotonic_darwin() u64 {
        assert(is_darwin);
        // Uses mach_continuous_time() instead of mach_absolute_time() as it counts while suspended.
        //
        // https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.c.auto.html
        const darwin = struct {
            const mach_timebase_info_t = system.mach_timebase_info_data;
            extern "c" fn mach_timebase_info(info: *mach_timebase_info_t) system.kern_return_t;
            extern "c" fn mach_continuous_time() u64;
        };

        // mach_timebase_info() called through libc already does global caching for us
        //
        // https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/mach_timebase_info.c.auto.html
        var info: darwin.mach_timebase_info_t = undefined;
        if (darwin.mach_timebase_info(&info) != 0) @panic("mach_timebase_info() failed");

        const now = darwin.mach_continuous_time();
        return (now * info.numer) / info.denom;
    }

    fn monotonic_linux() u64 {
        assert(is_linux);
        // The true monotonic clock on Linux is not in fact CLOCK_MONOTONIC:
        //
        // CLOCK_MONOTONIC excludes elapsed time while the system is suspended (e.g. VM migration).
        //
        // CLOCK_BOOTTIME is the same as CLOCK_MONOTONIC but includes elapsed time during a suspend.
        //
        // For more detail and why CLOCK_MONOTONIC_RAW is even worse than CLOCK_MONOTONIC, see
        // https://github.com/ziglang/zig/pull/933#discussion_r656021295.
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.BOOTTIME) catch {
            @panic("CLOCK_BOOTTIME required");
        };
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    fn realtime(_: *anyopaque) i64 {
        //if (is_windows) return realtime_windows();
        // macos has supported clock_gettime() since 10.12:
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.3.auto.html
        if (is_darwin or is_linux) return realtime_unix();
        @compileError("unsupported OS");
    }

    // fn realtime_windows() i64 {
    //     // TODO(zig): Maybe use `std.time.nanoTimestamp()`.
    //     // https://github.com/ziglang/zig/pull/22871
    //     assert(is_windows);
    //     var ft: os.windows.FILETIME = undefined;
    //     stdx.windows.GetSystemTimePreciseAsFileTime(&ft);
    //     const ft64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;

    //     // FileTime is in units of 100 nanoseconds
    //     // and uses the NTFS/Windows epoch of 1601-01-01 instead of Unix Epoch 1970-01-01.
    //     const epoch_adjust = std.time.epoch.windows * (std.time.ns_per_s / 100);
    //     return (@as(i64, @bitCast(ft64)) + epoch_adjust) * 100;
    // }

    fn realtime_unix() i64 {
        assert(is_darwin or is_linux);
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
        return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    fn tick(_: *anyopaque) void {}
};

/// Equivalent to `std.time.Timer`,
/// but using the `vsr.Time` interface as the source of time.
pub const Timer = struct {
    time: Time,
    started: Instant,

    pub fn init(time: Time) Timer {
        return .{
            .time = time,
            .started = time.monotonic(),
        };
    }

    /// Reads the timer value since start or the last reset.
    pub fn read(self: *Timer) Duration {
        const current = self.time.monotonic();
        assert(current.ns >= self.started.ns);
        return current.duration_since(self.started);
    }

    /// Resets the timer.
    pub fn reset(self: *Timer) void {
        const current = self.time.monotonic();
        assert(current.ns >= self.started.ns);
        self.started = current;
    }
};
