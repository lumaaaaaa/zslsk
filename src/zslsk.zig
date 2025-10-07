const std = @import("std");

pub const Client = struct {
    // properties //
    allocator: std.mem.Allocator,

    // initialization function //
    pub fn init(allocator: std.mem.Allocator) Client {
        return .{ .allocator = allocator };
    }

    // deinitialization function //
    pub fn deinit(self: *Client) void {
        _ = self;
        // TODO:: as properties grow, deallocate them here
    }

    // library functions //
    pub fn connect(self: *Client, username: []const u8, password: []const u8) !void {
        _ = self;
        _ = username;
        _ = password;
        return;
    }
};
