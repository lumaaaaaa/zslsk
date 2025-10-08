const std = @import("std");

/// Defines the structure for a Room on the Soulseek network.
pub const Room = struct {
    name: []const u8,
    user_count: u32,
};
