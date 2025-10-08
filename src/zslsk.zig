const std = @import("std");
const messages = @import("messages.zig");

pub const Client = struct {
    // properties //
    allocator: std.mem.Allocator,
    socket: ?std.net.Stream,

    // initialization function //
    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .socket = null,
        };
    }

    // deinitialization function //
    pub fn deinit(self: *Client) void {
        // TODO:: as properties grow, deallocate them here
        if (self.socket) |socket| {
            socket.close(); // close TCP connection
        }
    }

    // public library functions //
    /// Connects to a Soulseek server and authenticates with the supplied username and password.
    pub fn connect(self: *Client, hostname: []const u8, port: u16, username: []const u8, password: []const u8) !void {
        // connect to server
        std.log.debug("Establishing TCP connection to host {s}:{d}...", .{ hostname, port });
        self.socket = try std.net.tcpConnectToHost(self.allocator, hostname, port);
        std.log.debug("TCP connection successful.", .{});

        // hash credentials
        var md5 = std.crypto.hash.Md5.init(.{});
        md5.update(username);
        md5.update(password);
        var hash: [16]u8 = undefined;
        md5.final(&hash);
        const hash_hex = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)});
        defer self.allocator.free(hash_hex);

        // authentication step 1 (send login message)
        const login_msg = messages.LoginMessage{
            .hash = hash_hex,
            .minor_version = 1,
            .version = 160,
            .username = username,
            .password = password,
        };

        std.log.debug("Sending login message to server...", .{});
        try self.sendMessage(.{ .login = login_msg });
        std.log.debug("Sent login message successfully.", .{});

        // authentication step 2 (receive login message)
        var buf: [4096]u8 = undefined;
        var reader = self.socket.?.reader(&buf);

        std.log.debug("Reading login response from server...", .{});
        var login_response = try messages.LoginResponse.parse(self.allocator, &reader.file_reader.interface);
        defer login_response.deinit(self.allocator);

        if (!login_response.success) {
            std.log.err("Login failed: {s}", .{login_response.rejection_reason.?});
            return error.LoginFailed;
        } else {
            std.log.debug("Login successful. {s}", .{login_response.greeting.?});
        }

        return;
    }

    // private internal functions //
    /// Internal function to send a message to the server.
    fn sendMessage(self: *Client, msg: messages.Message) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var buf: [512]u8 = undefined;
        var writer = self.socket.?.writer(&buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }
};
