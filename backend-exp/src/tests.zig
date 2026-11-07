//! `zig build test` (routes in memory); unit tests run from src/main.zig.
test {
    _ = @import("integration_test.zig");
    _ = @import("remote_test.zig");
    _ = @import("hooks_test.zig");
    _ = @import("usage_test.zig");
    _ = @import("local_test.zig");
}
