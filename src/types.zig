const std = @import("std");

/// Defines the structure for a Room on the Soulseek network.
pub const Room = struct {
    name: []const u8,
    user_count: u32,
};

/// Enum representing possible connection types.
pub const ConnectionType = enum {
    P, // p2p
    F, // file transfer
    D, // distributed network
};
