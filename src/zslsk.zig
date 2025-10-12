const std = @import("std");
const messages = @import("messages.zig");
const types = @import("types.zig");

pub const Client = struct {
    // constants //
    const peerDialTimeoutMs: u64 = 5000;
    const peerMsgTimeoutMs: u64 = 5000;

    // properties //
    allocator: std.mem.Allocator,
    socket: ?std.net.Stream,
    read_buf: [65535]u8, // backing buffer for buffered reading from the socket
    socket_reader: ?std.net.Stream.Reader,
    centralized_thread: ?std.Thread,
    server: ?std.net.Server,
    running: std.atomic.Value(bool),

    // p2p connections
    p2p_thread: ?std.Thread,
    peer_connections: std.StringHashMap(*PeerConnection),
    peers_mutex: std.Thread.RwLock,

    // initialization function //
    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .socket = null,
            .read_buf = undefined,
            .socket_reader = null,
            .centralized_thread = null,
            .p2p_thread = null,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .peer_connections = std.StringHashMap(*PeerConnection).init(allocator),
            .peers_mutex = .{},
        };
    }

    // deinitialization function //
    pub fn deinit(self: *Client) void {
        // signal stop
        self.running.store(false, .seq_cst);

        // join threads
        if (self.p2p_thread) |thread| thread.join();
        if (self.centralized_thread) |thread| thread.join();

        // peer cleanup
        self.peers_mutex.lock();
        var peer_iter = self.peer_connections.valueIterator();
        while (peer_iter.next()) |peer| {
            peer.*.deinit();
            self.allocator.destroy(peer.*);
        }
        self.peer_connections.deinit();
        self.peers_mutex.unlock();

        // close sockets
        if (self.socket) |socket| socket.close();
        if (self.server) |*server| server.deinit();
    }

    // API accessible to library consumers //
    /// Connects to a Soulseek server and authenticates with the supplied username and password. Additionally, this function will
    /// start the network thread to asynchronously process messages from server -> client.
    pub fn connect(self: *Client, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
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

        // listen for p2p connections
        const address = std.net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, listen_port);
        self.server = try address.listen(.{});
        std.log.debug("listening on client public IPv4: {d}.{d}.{d}.{d}:{d}", .{
            login_response.login.ip_address.?[0],
            login_response.login.ip_address.?[1],
            login_response.login.ip_address.?[2],
            login_response.login.ip_address.?[3],
            listen_port,
        });

        // advertise port to server
        const set_wait_port_msg = messages.SetWaitPortMessage{
            .port = listen_port,
        };

        std.log.debug("Sending message to advertise p2p port...", .{});
        try self.sendMessage(.{ .setWaitPort = set_wait_port_msg });
        std.log.debug("Advertised p2p port successfully.", .{});

        // we're ready to run background threads
        self.running.store(true, .seq_cst);
        self.centralized_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        self.p2p_thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        return;
    }

    pub fn getUserInfo(self: *Client, username: []const u8) !messages.UserInfoMessage {
        // first, see if we need to establish a connection with this peer
        self.peers_mutex.lockShared();
        const existing_conn_or_null = self.peer_connections.get(username);
        defer self.peers_mutex.unlockShared();

        if (existing_conn_or_null == null) {
            // we need to connect to this peer
        }

        // a connection is established at this point
        const conn = existing_conn_or_null.?;

        // send message to request peer's user info
        try conn.sendPeerMessage(.{ .getUserInfo = messages.EmptyMessage{} });

        // wait for a response
        const response = try conn.user_info_slot.waitForResponse(peerMsgTimeoutMs);

        return response;
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
            18 => .{ .connectToPeer = try messages.ConnectToPeerResponse.parse(reader_interface, self.allocator) },
            22 => .{ .messageUser = try messages.MessageUserResponse.parse(reader_interface, self.allocator) },
            64 => .{ .roomList = try messages.RoomListResponse.parse(reader_interface, self.allocator) },
            69 => .{ .privilegedUsers = try messages.PrivilegedUsersResponse.parse(reader_interface, self.allocator) },
            83 => .{ .parentMinSpeed = try messages.ParentMinSpeedResponse.parse(reader_interface) },
            84 => .{ .parentSpeedRatio = try messages.ParentSpeedRatioResponse.parse(reader_interface) },
            104 => .{ .wishlistSearch = try messages.WishlistSearchResponse.parse(reader_interface) },
            160 => .{ .excludedSearchPhrases = try messages.ExcludedSearchPhrasesResponse.parse(reader_interface, self.allocator) },
            else => {
                std.log.warn("server readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

                // discard
                const remaining: usize = payload_len - 4;
                try reader_interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }

    /// Esablishes a TCP connection, or returns error if the connection times out.
    fn tcpConnectToAddressTimeout(address: std.net.Address, timeout_ms: u64) !std.net.Stream {
        // create stream object
        var socket: ?std.net.Stream = null;

        // function to dial
        const T = struct {
            fn bgDial(sock: *?std.net.Stream, addr: std.net.Address) void {
                sock.* = std.net.tcpConnectToAddress(addr) catch |err| {
                    std.log.err("Could not establish TCP connection: {}", .{err});
                    return;
                };
            }
        };

        // dial in background
        var thread = try std.Thread.spawn(.{}, T.bgDial, .{ &socket, address });
        defer thread.join();

        // continue sleeping while socket disconnected, up to timeout
        const check_interval = 10; // 10ms
        var total_sleep: u64 = 0;
        while (socket == null and total_sleep < timeout_ms) {
            std.Thread.sleep(check_interval * std.time.ns_per_ms);
            total_sleep += check_interval;
        }

        if (socket) |sock| {
            return sock;
        }

        return error.DialTimeout;
    }

    /// Message handler for ConnectToPeer, establishes an indirect peer connection.
    fn handleConnectToPeer(self: *Client, msg: messages.ConnectToPeerResponse) !void {
        // check for existing p2p connection
        self.peers_mutex.lock(); // handleConnectToPeer and handleIncomingPeerConnection must not race
        const existing_conn = self.peer_connections.get(msg.username);
        defer self.peers_mutex.unlock();

        if (existing_conn) |_| {
            std.log.debug("Connection to peer {s} already exists", .{msg.username});
            return;
        }

        // TODO: handle different connection types
        const connection_type = std.meta.stringToEnum(types.ConnectionType, msg.type);
        switch (connection_type.?) {
            // p2p
            types.ConnectionType.P => |conn_type| {
                std.log.debug("Establishing indirect P connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
                    msg.username,
                    msg.ip[0],
                    msg.ip[1],
                    msg.ip[2],
                    msg.ip[3],
                    msg.port,
                });

                // connect to host
                const address = std.net.Address.initIp4(msg.ip, @intCast(msg.port));
                const socket = tcpConnectToAddressTimeout(address, peerDialTimeoutMs) catch |err| {
                    std.log.err("Timed out when connecting to peer: {}", .{err});
                    return err;
                };

                // create PeerConnection
                const peer = try PeerConnection.init(self.allocator, socket, msg.username, msg.token, conn_type, null, null);

                // send PierceFireWall
                try peer.sendPierceFireWall();

                // add to peer map
                try self.peer_connections.put(peer.username, peer);

                // spawn thread for independent peer read loop
                try peer.beginReadLoop(self);

                std.log.debug("Established connection with peer.", .{});
            },
            types.ConnectionType.F => {
                // file transfer
            },
            types.ConnectionType.D => {
                // distributed network
            },
        }
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
                .connectToPeer => |resp| {
                    std.log.debug("\tP2P connection requested! {s} with address {d}.{d}.{d}.{d}:{d} wants connection type {s}, token {d}", .{
                        resp.username,
                        resp.ip[0],
                        resp.ip[1],
                        resp.ip[2],
                        resp.ip[3],
                        resp.port,
                        resp.type,
                        resp.token,
                    });

                    self.handleConnectToPeer(resp) catch |err| {
                        std.log.err("Could not connect to peer: {}", .{err});
                    };
                },
                .messageUser => |resp| {
                    std.log.info("\tPrivate chat received | {s}: {s}", .{ resp.username, resp.message });
                },
                .roomList => |resp| std.log.debug("\tRoom counts: {d} total, {d} owned private, {d} unowned private, {d} operated private", .{ resp.rooms.capacity, resp.owned_private_rooms.capacity, resp.unowned_private_rooms.capacity, resp.operated_private_rooms.capacity }),
                .privilegedUsers => |resp| std.log.debug("\tPrivileged user count: {d}", .{resp.users.capacity}), // just print for now
                .parentMinSpeed => |resp| std.log.debug("\tMinimum upload speed to become parent: {d}", .{resp.speed}), // just print for now
                .parentSpeedRatio => |resp| std.log.debug("\tParent speed ratio: {d}", .{resp.ratio}), // just print for now
                .wishlistSearch => |resp| std.log.debug("\tWishlist search interval: {d} seconds", .{resp.interval}), // just print for now
                .excludedSearchPhrases => |resp| std.log.debug("\tExcluded search phrase count: {d}", .{resp.phrases.capacity}), // TODO: store these phrases, search requests should exclude paths containing these strings
            }
        }
    }

    /// PeerInit is a special case of peer message. It's the only peer message readable outside of a PeerConnection.
    fn readPeerInit(self: *Client, reader: *std.Io.Reader) !messages.PeerInit {
        return try messages.PeerInit.parse(self.allocator, reader);
    }

    // Handles an incoming peer connection and adds a PeerConnection object to our peer_connections.
    fn handleIncomingPeerConnection(self: *Client, socket: std.net.Stream) !void {
        self.peers_mutex.lock(); // handleConnectToPeer and handleIncomingPeerConnection must not race
        defer self.peers_mutex.unlock();

        var buf: [65535]u8 = undefined;
        var reader = socket.reader(&buf);

        // get reader interface
        var reader_interface = reader.interface();

        // parse message header
        try reader_interface.discardAll(4); // we don't need the length for PeerInit
        const message_code = try reader_interface.takeByte();

        // ensure this is a PeerInit message before we parse
        if (message_code != 1) {
            std.log.err("Expected PeerInit on incoming connection, instead got code {d}.", .{message_code});
            return error.UnknownMessage;
        }

        const msg = try self.readPeerInit(reader.interface());

        // create PeerConnection
        const peer = try PeerConnection.init(self.allocator, socket, msg.username, msg.token, std.meta.stringToEnum(types.ConnectionType, msg.type).?, reader, buf);

        // add to peer map
        try self.peer_connections.put(peer.username, peer);

        // spawn thread for independent peer read loop
        try peer.beginReadLoop(self);

        std.log.debug("Connection established with {s}", .{msg.username});
    }

    /// Peer-to-peer server loop. Accepts connections and adds them to
    fn serverLoop(self: *Client) void {
        while (self.running.load(.seq_cst)) {
            const client = self.server.?.accept() catch |err| {
                std.log.err("Error encountered accepting p2p connection: {}", .{err});
                continue;
            };

            const client_addr = client.address;
            std.log.debug("Handling p2p connection from client with IP: {any}", .{client_addr.in});

            self.handleIncomingPeerConnection(client.stream) catch |err| {
                std.log.err("Error encountered handling incoming p2p connection: {}", .{err});
            };
        }
    }

    /// Removes a peer from the pool.
    fn removePeer(self: *Client, username: []const u8) void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        if (self.peer_connections.fetchRemove(username)) |kv| {
            const peer = kv.value;
            std.log.debug("Removing peer {s} from pool", .{username});

            // should do the heavy lifting for us
            peer.deinit();
        } else {
            std.log.debug("Attempted to remove non-existent peer: {s}", .{username});
        }
    }
};

// Represents an open connection to a peer.
pub const PeerConnection = struct {
    // properties
    allocator: std.mem.Allocator,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // connection
    socket: std.net.Stream,
    socket_reader: std.net.Stream.Reader,
    read_buf: [65535]u8,
    write_buf: [8192]u8,
    connection_type: types.ConnectionType,

    // peer info
    username: []const u8,
    token: u32,

    // synchronous responses
    user_info_slot: ResponseSlot(messages.UserInfoMessage),

    pub fn deinit(self: *PeerConnection) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.socket.close();
        self.allocator.free(self.username);
    }

    pub fn init(allocator: std.mem.Allocator, socket: std.net.Stream, username: []const u8, token: u32, connection_type: types.ConnectionType, socket_reader: ?std.net.Stream.Reader, read_buf: ?[65535]u8) !*PeerConnection {
        const conn = try allocator.create(PeerConnection);

        conn.* = .{
            .allocator = allocator,
            .thread = null,
            .running = std.atomic.Value(bool).init(true),
            .socket = socket,
            .socket_reader = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
            .connection_type = connection_type,
            .username = try allocator.dupe(u8, username),
            .token = token,
            .user_info_slot = .{},
        };

        if (read_buf) |b| {
            conn.read_buf = b;
        }

        if (socket_reader) |r| {
            conn.socket_reader = r;
        } else {
            conn.socket_reader = socket.reader(&conn.read_buf);
        }

        return conn;
    }

    // public library functions //
    pub fn sendPierceFireWall(self: *PeerConnection) !void {
        const msg = messages.PierceFireWall{
            .token = self.token,
        };

        try self.sendPeerInitMessage(.{ .pierceFireWall = msg });
    }

    pub fn beginReadLoop(self: *PeerConnection, client: *Client) !void {
        self.thread = try std.Thread.spawn(.{}, readLoop, .{ self, client });
    }

    // private internal functions //
    fn sendPeerInitMessage(self: *PeerConnection, msg: messages.PeerInitMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var writer = self.socket.writer(&self.write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    fn sendPeerMessage(self: *PeerConnection, msg: messages.PeerMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var writer = self.socket.writer(&self.write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    fn readResponse(self: *PeerConnection) !messages.PeerMessage {
        // get reader interface
        var reader_interface = self.socket_reader.interface();

        // parse message header
        const payload_len = try reader_interface.takeInt(u32, .little);
        const start_seek = reader_interface.seek; // current_seek - start_seek < payload_len, keep parsing
        const message_code = try reader_interface.takeInt(u32, .little);

        // handoff to relevant parser
        return switch (message_code) {
            4 => .{ .getSharedFileList = try messages.EmptyMessage.parse(self.allocator, reader_interface) },
            5 => .{ .sharedFileList = try messages.SharedFileListMessage.parse(self.allocator, reader_interface) },
            15 => .{ .getUserInfo = try messages.EmptyMessage.parse(self.allocator, reader_interface) },
            16 => .{ .userInfo = try messages.UserInfoMessage.parse(self.allocator, reader_interface, start_seek, payload_len) },
            else => {
                std.log.warn("Peer readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

                // discard
                const remaining: usize = payload_len - 4;
                try reader_interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }

    fn readLoop(self: *PeerConnection, client: *Client) void {
        while (self.running.load(.seq_cst)) {
            var message = self.readResponse() catch |err| {
                if (err == error.EndOfStream) {
                    std.log.debug("Peer {s} disconnected", .{self.username});
                    client.removePeer(self.username);
                    break;
                }
                std.log.debug("err: {}", .{err});
                continue;
            };

            // deinit message if it isn't returned
            var should_deinit = true;
            defer if (should_deinit) message.deinit(self.allocator);

            // handle async message types
            std.log.debug("== Received message: {s} (code: {d}) ==", .{ @tagName(message), message.code() });
            switch (message) {
                .getSharedFileList => {
                    std.log.debug("\t{s} requests our shared files", .{self.username});
                    const msg = messages.SharedFileListMessage{
                        .data = "",
                    };
                    self.sendPeerMessage(.{ .sharedFileList = msg }) catch |err| {
                        std.log.err("Failed sending file list: {}", .{err});
                        continue;
                    };
                },
                .sharedFileList => {
                    std.log.debug("\tReceived {s}'s file list (parsing unimplemented)", .{self.username});
                },
                .getUserInfo => {
                    std.log.debug("\t{s} requests our user info", .{self.username});
                    // TODO: implement some form of user profile properties to source this data from
                    const msg = messages.UserInfoMessage{
                        .description = "hello from zslsk",
                        .picture = null,
                        .queue_size = 0,
                        .slots_free = true,
                        .total_upload = 420,
                        .upload_permitted = .everyone,
                    };
                    self.sendPeerMessage(.{ .userInfo = msg }) catch |err| {
                        std.log.err("Failed sending user info: {}", .{err});
                        continue;
                    };
                    std.log.debug("Sent {s} our user info", .{self.username});
                },
                .userInfo => |msg| {
                    std.log.debug("\tReceived {s}'s user info", .{self.username});
                    should_deinit = false;
                    // set response in user info response slot
                    self.user_info_slot.setResponse(msg);
                },
            }
        }
    }
};

// Type allowing for easy synchronous message handling.
fn ResponseSlot(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        event: std.Thread.ResetEvent = .{},
        response: ?T = null,

        pub fn waitForResponse(self: *@This(), timeout_ms: ?u64) !T {
            // clear event
            self.event.reset();

            if (timeout_ms) |timeout| {
                // wait for event with timeout
                try self.event.timedWait(timeout * std.time.ns_per_ms);
            } else {
                // no timeout specified, just wait for event
                self.event.wait();
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            const response = self.response orelse return error.NoResponse;
            self.response = null; // clear slot
            return response;
        }

        pub fn setResponse(self: *@This(), response: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.response = response;
            self.event.set();
        }
    };
}
