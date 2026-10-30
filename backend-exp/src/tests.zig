//! `zig build test` (routes in memory); unit tests run from src/main.zig.
test {
    _ = @import("integration_test.zig");
    _ = @import("remote_test.zig");
}
