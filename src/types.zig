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

/// Structure representing a client's configurable user info to share with peers.
pub const UserInfoConfig = struct {
    description: []const u8, // a biography essentially
    picture: ?[]const u8, // an optional profile picture
};
