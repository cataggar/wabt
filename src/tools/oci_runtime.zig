//! Injectable boundary for OCI command side effects.
//!
//! The shell increment never calls these operations. Counters make that
//! property explicit in tests and give later execution increments one place
//! to attach networking, discovery, helper, and secret-input behavior.

pub const Counters = struct {
    network_clients: usize = 0,
    credential_discoveries: usize = 0,
    helper_runs: usize = 0,
    stdin_reads: usize = 0,

    pub fn isZero(self: Counters) bool {
        return self.network_clients == 0 and
            self.credential_discoveries == 0 and
            self.helper_runs == 0 and
            self.stdin_reads == 0;
    }
};

pub const Runtime = struct {
    counters: *Counters,

    pub fn init(counters: *Counters) Runtime {
        return .{ .counters = counters };
    }

    pub fn createNetworkClient(self: *Runtime) void {
        self.counters.network_clients += 1;
    }

    pub fn discoverCredentials(self: *Runtime) void {
        self.counters.credential_discoveries += 1;
    }

    pub fn runCredentialHelper(self: *Runtime) void {
        self.counters.helper_runs += 1;
    }

    pub fn readSecretStdin(self: *Runtime) void {
        self.counters.stdin_reads += 1;
    }
};

test "runtime counters start at zero and count each boundary" {
    const std = @import("std");
    var counters: Counters = .{};
    var runtime = Runtime.init(&counters);
    try std.testing.expect(counters.isZero());
    runtime.createNetworkClient();
    runtime.discoverCredentials();
    runtime.runCredentialHelper();
    runtime.readSecretStdin();
    try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
    try std.testing.expectEqual(@as(usize, 1), counters.credential_discoveries);
    try std.testing.expectEqual(@as(usize, 1), counters.helper_runs);
    try std.testing.expectEqual(@as(usize, 1), counters.stdin_reads);
}
