const std = @import("std");
const zio = @import("zio");

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

/// Structure representing the result of race between direct and indirect connection paths.
pub const ConnectionResult = struct {
    stream: zio.net.Stream,
    direct: bool,
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

/// Structure representing a upload in the client's queue.
pub const QueuedUpload = struct {
    username: []const u8,
    filename: []const u8,
    real_path: []const u8,
    size: u64,

    pub fn deinit(self: *QueuedUpload, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.filename);
        allocator.free(self.real_path);
    }
};
