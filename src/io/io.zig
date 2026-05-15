const builtin = @import("builtin");
const io = if (builtin.os.tag == .linux) @import("../io/linux.zig") else @import("../io/darwin.zig");
pub const IO = io.IO;
