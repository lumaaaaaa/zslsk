const std = @import("std");
const messages = @import("messages.zig");

pub const Client = struct {
    // properties //
    allocator: std.mem.Allocator,
    socket: ?std.net.Stream,
    read_buf: [65535]u8, // backing buffer for buffered reading from the socket
    socket_reader: ?std.net.Stream.Reader,
    network_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // initialization function //
    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .socket = null,
            .read_buf = undefined,
            .socket_reader = null,
            .network_thread = null,
            .running = std.atomic.Value(bool).init(false),
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
    /// Connects to a Soulseek server and authenticates with the supplied username and password. Additionally, this function will
    /// start the network thread to asynchronously process messages from server -> client.
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

        // initialize socket reader
        self.socket_reader = self.socket.?.reader(&self.read_buf);

        // authentication step 2 (receive login message)
        std.log.debug("Reading login response from server...", .{});
        var login_response = try self.readResponse();
        defer login_response.deinit(self.allocator);

        if (!login_response.login.success) {
            std.log.err("Login failed: {s}", .{login_response.login.rejection_reason.?});
            return error.LoginFailed;
        } else {
            std.log.debug("Login successful. {s}", .{login_response.login.greeting.?});
        }

        // we're ready to run background threads
        self.running.store(true, .seq_cst);
        self.network_thread = try std.Thread.spawn(.{}, readLoop, .{self});

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

    /// Internal function to read a response from the server.
    fn readResponse(self: *Client) !messages.Response {
        // get reader interface
        var reader_interface = self.socket_reader.?.interface();

        // parse message header
        const payload_len = try reader_interface.takeInt(u32, .little);
        const message_code = try reader_interface.takeInt(u32, .little);

        // handoff to relevant parser
        return switch (message_code) {
            1 => .{ .login = try messages.LoginResponse.parse(reader_interface, self.allocator, payload_len) },
            64 => .{ .roomList = try messages.RoomListResponse.parse(reader_interface, self.allocator) },
            69 => .{ .privilegedUsers = try messages.PrivilegedUsersResponse.parse(reader_interface, self.allocator) },
            83 => .{ .parentMinSpeed = try messages.ParentMinSpeedResponse.parse(reader_interface) },
            84 => .{ .parentSpeedRatio = try messages.ParentSpeedRatioResponse.parse(reader_interface) },
            104 => .{ .wishlistSearch = try messages.WishlistSearchResponse.parse(reader_interface) },
            160 => .{ .excludedSearchPhrases = try messages.ExcludedSearchPhrasesResponse.parse(reader_interface, self.allocator) },
            else => {
                std.log.warn("readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

                // discard
                const remaining: usize = payload_len - 4;
                try reader_interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }

    /// Message read loop, hands off messages for async handling and holds synchronous messages till handled.
    fn readLoop(self: *Client) void {
        while (self.running.load(.seq_cst)) {
            var message = self.readResponse() catch continue;
            defer message.deinit(self.allocator);

            // handle async message types
            std.log.debug("== Received message: {s} (code: {d}) ==", .{ @tagName(message), message.code() });
            switch (message) {
                .login => continue, // do nothing, we handle logins just once, synchronously on connect
                .roomList => |resp| std.log.debug("\tRoom counts: {d} total, {d} owned private, {d} unowned private, {d} operated private", .{ resp.rooms.capacity, resp.owned_private_rooms.capacity, resp.unowned_private_rooms.capacity, resp.operated_private_rooms.capacity }),
                .privilegedUsers => |resp| std.log.debug("\tPrivileged user count: {d}", .{resp.users.capacity}), // just print for now
                .parentMinSpeed => |resp| std.log.debug("\tMinimum upload speed to become parent: {d}", .{resp.speed}), // just print for now
                .parentSpeedRatio => |resp| std.log.debug("\tParent speed ratio: {d}", .{resp.ratio}), // just print for now
                .wishlistSearch => |resp| std.log.debug("\tWishlist search interval: {d} seconds", .{resp.interval}), // just print for now
                .excludedSearchPhrases => |resp| std.log.debug("\tExcluded search phrase count: {d}", .{resp.phrases.capacity}), // TODO: store these phrases, search requests should exclude paths containing these strings
            }
        }
    }
};
