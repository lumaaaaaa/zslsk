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

/// Enum representing what type of handshake must be done on a connection.
pub const HandshakeType = enum {
    outgoing_direct, // we connect directly - PeerInit
    outgoing_indirect, // we connect indirectly - PierceFireWall
    incoming, // they connected to us (and sent PeerInit) - none
};

/// Structure representing a client's configurable user info to share with peers.
pub const UserInfoConfig = struct {
    description: []const u8, // a biography essentially
    picture: ?[]const u8, // an optional profile picture
};
