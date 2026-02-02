const std = @import("std");
const messages = @import("messages.zig");
const types = @import("types.zig");
const zio = @import("zio");

pub const ConnectionState = enum(u8) {
    disconnected,
    connecting,
    connected,
    failed,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected), // connection state
    socket: ?zio.net.Stream, // socket connection to centralized server
    p2p_server: ?zio.net.Server, // server listening for p2p connections
    peers: std.StringHashMap(*PeerConnection), // established peer connections
    peers_mutex: std.Thread.Mutex = .{},
    own_username: ?[]const u8,

    // group for peer task execution
    peer_group: ?*zio.Group,

    // oneshot channels for request-response, keyed by username for concurrency
    get_peer_address_channels: std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)),
    waiters_mutex: std.Thread.Mutex = .{},

    /// Exported Library Functions ///
    pub fn init(allocator: std.mem.Allocator) !Client {
        return .{
            .allocator = allocator,
            .socket = null,
            .p2p_server = null,
            .peers = std.StringHashMap(*PeerConnection).init(allocator),
            .own_username = null,
            .peer_group = null,
            .get_peer_address_channels = std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        // disconnect
        self.connection_state.store(.disconnected, .seq_cst);
        if (self.own_username) |username| self.allocator.free(username);
    }

    /// Connects and authenticates with a Soulseek server. Begins the async runtime.
    pub fn run(self: *Client, rt: *zio.Runtime, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
        // store own username
        self.own_username = username;

        // connect to server
        std.log.debug("Establishing TCP connection to host {s}:{d}...", .{ hostname, port });
        self.socket = try zio.net.tcpConnectToHost(rt, hostname, port, .{ .timeout = .none });
        std.log.debug("TCP connection successful.", .{});

        // initialize socket reader and writer
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.?.reader(rt, &read_buf);

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
        try self.sendMessage(rt, .{ .login = login_msg });
        std.log.debug("Sent login message successfully.", .{});

        // authentication step 2 (receive login message)
        std.log.debug("Reading login response from server...", .{});
        var login_response = try self.readResponse(&reader);
        defer login_response.deinit(self.allocator);

        if (!login_response.login.success) {
            std.log.err("Login failed: {s}", .{login_response.login.rejection_reason.?});
            return error.LoginFailed;
        } else {
            std.log.debug("Login successful. {s}", .{login_response.login.greeting.?});
        }

        // we're connected!
        self.connection_state.store(.connected, .seq_cst);

        // dispatch concurrent tasks
        var peer_group: zio.Group = .init;
        self.peer_group = &peer_group;
        defer self.peer_group.?.cancel(rt);

        _ = listen_port;
        //try self.peer_group.?.spawn(rt, p2pListenerTask, .{ self, rt, listen_port }); // p2p listener

        // begin read loop
        self.readLoop(rt, &reader);

        self.peer_group.?.wait(rt) catch {};
    }

    /// Gets user info of the user with the specified username.
    pub fn getUserInfo(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.UserInfoMessage {
        // get the peer
        const conn = try self.getPeer(rt, username);

        // get user info
        return try conn.getUserInfo(rt);
    }

    /// Sends a direct message to a user through the centralized server.
    pub fn messageUser(self: *Client, rt: *zio.Runtime, username: []const u8, text: []const u8) !void {
        // construct message
        const message_user_msg = messages.MessageUserMessage{
            .username = username,
            .message = text,
        };

        // send to server
        try self.sendMessage(rt, .{ .messageUser = message_user_msg });
    }

    pub fn getPeerAddress(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.GetPeerAddressResponse {
        // create oneshot channel for request-response
        var one: [1]messages.GetPeerAddressResponse = undefined;
        var channel = zio.Channel(messages.GetPeerAddressResponse).init(&one);
        defer channel.close(.graceful);

        // register
        self.waiters_mutex.lock();
        try self.get_peer_address_channels.put(username, &channel);
        self.waiters_mutex.unlock();

        // unregister on exit
        defer {
            self.waiters_mutex.lock();
            _ = self.get_peer_address_channels.remove(username);
            self.waiters_mutex.unlock();
        }

        // request peer address
        try self.sendMessage(rt, .{ .getPeerAddress = messages.GetPeerAddressMessage{ .username = username } });

        // block until we receive a response
        return channel.receive(rt);
    }

    /// Internal Library Functions ///
    // P2P listener.
    fn p2pListenerTask(self: *Client, rt: *zio.Runtime, listen_port: u16) void {
        // listen for p2p connections
        const listen_addr = try zio.net.IpAddress.parseIp4("0.0.0.0", listen_port);
        self.p2p_server = try listen_addr.listen(rt, .{});
        std.log.debug("Listening for P2P connections on port {d}", .{
            listen_port,
        });

        // advertise port to server
        const set_wait_port_msg = messages.SetWaitPortMessage{
            .port = listen_port,
        };

        std.log.debug("Sending message to advertise P2P port...", .{});
        try self.sendMessage(rt, .{ .setWaitPort = set_wait_port_msg });
        std.log.debug("Advertised P2P port successfully.", .{});

        while (self.connection_state.load(.seq_cst) == .connected) {
            const stream = self.p2p_server.?.accept(rt) catch |err| {
                std.log.warn("P2P accept error: {}", .{err});
                continue;
            };
            errdefer stream.close(rt);

            std.log.debug("Incoming P2P connection from {f}", .{stream.socket.address});
            //try peer_group.spawn(rt, handleIncomingPeer, .{ self, rt, stream });
        }
    }

    // Server read loop.
    fn readLoop(self: *Client, rt: *zio.Runtime, reader: *zio.net.Stream.Reader) void {
        while (self.connection_state.load(.seq_cst) == .connected) {
            var message = self.readResponse(reader) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };

            // deinit message if it isn't returned
            var should_deinit = true;
            defer if (should_deinit) message.deinit(self.allocator);

            // handle async message types
            std.log.debug("== Received message: {s} (code: {d}) ==", .{ @tagName(message), message.code() });
            switch (message) {
                .login => continue, // do nothing, we handle logins just once, synchronously on connect
                .getPeerAddress => |resp| {
                    std.log.debug("\tReceived {s}'s address", .{resp.username});
                    should_deinit = false;

                    // send response in corresponding user info oneshot channel
                    if (self.get_peer_address_channels.get(resp.username)) |channel| {
                        channel.send(rt, resp) catch |err| {
                            std.log.err("Could not send GetPeerAddressResponse in oneshot channel: {}", .{err});
                        };
                    }
                },
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
                    should_deinit = false;

                    if (self.peer_group) |group| {
                        group.spawn(rt, handleConnectToPeer, .{ self, rt, resp }) catch |err| {
                            std.log.err("Could not spawn thread to handle ConnectToPeer message: {}", .{err});
                        };
                    }
                },
                .messageUser => |resp| {
                    std.log.info("\tPrivate chat received | {s}: {s}", .{ resp.username, resp.message });

                    // construct acknowledgement message
                    const message_acked_msg = messages.MessageAckedMessage{
                        .message_id = resp.id,
                    };

                    // send to server
                    self.sendMessage(rt, .{ .messageAcked = message_acked_msg }) catch |err| {
                        std.log.err("Could not send private chat acknowledgement: {}", .{err});
                    };

                    std.log.debug("Acknowledged private chat receipt", .{});
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

    // Message handler for ConnectToPeer, establishes an indirect peer connection.
    fn handleConnectToPeer(self: *Client, rt: *zio.Runtime, resp: messages.ConnectToPeerResponse) void {
        var msg = resp;
        defer msg.deinit(self.allocator);

        // check for existing p2p connection
        self.peers_mutex.lock();
        const existing_conn = self.peers.get(msg.username);
        self.peers_mutex.unlock();

        if (existing_conn) |_| {
            std.log.debug("Connection to peer {s} already exists", .{msg.username});
            return;
        }

        // TODO: handle different connection types
        const connection_type = std.meta.stringToEnum(types.ConnectionType, msg.type);
        switch (connection_type.?) {
            // p2p
            types.ConnectionType.P => |conn_type| {
                // connect to peer
                const peer = self.createPeerConnection(rt, msg.ip, @intCast(msg.port), msg.username, msg.token, conn_type) catch |err| {
                    std.log.err("Error connecting to peer: {}", .{err});
                    return;
                };

                // spawn peer and run
                self.spawnPeer(rt, peer, false) catch |err| {
                    std.log.err("Error spawning & running peer: {}", .{err});
                };
            },
            types.ConnectionType.F => {
                // file transfer
            },
            types.ConnectionType.D => {
                // distributed network
            },
        }
    }

    // Gets an existing PeerConnection, or establishes one if needed.
    fn getPeer(self: *Client, rt: *zio.Runtime, username: []const u8) !*PeerConnection {
        // first, see if we need to establish a connection with this peer
        self.peers_mutex.lock();
        const existing_conn_or_null = self.peers.get(username);
        self.peers_mutex.unlock();

        if (existing_conn_or_null) |conn| return conn;
        // we need to connect to this peer
        // attempt a direct connection first

        // request peer address
        const get_peer_address_resp = try self.getPeerAddress(rt, username);

        // connect to peer
        const peer = try self.createPeerConnection(rt, get_peer_address_resp.ip, @intCast(get_peer_address_resp.port), username, 0, .P);

        // spawn peer and run
        try self.spawnPeer(rt, peer, true);

        return peer;
    }

    // Creates a peer connection and registers it. Does NOT start the read loop.
    fn createPeerConnection(self: *Client, rt: *zio.Runtime, ip: [4]u8, port: u16, username: []const u8, token: u32, connection_type: types.ConnectionType) !*PeerConnection {
        std.log.debug("Establishing {s} connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
            @tagName(connection_type),
            username,
            ip[0],
            ip[1],
            ip[2],
            ip[3],
            port,
        });

        // connect to host
        const address = zio.net.IpAddress.initIp4(ip, port);
        const socket = try zio.net.tcpConnectToAddress(rt, address, .{
            .timeout = .{ .duration = .fromSeconds(20) },
        });

        errdefer socket.close(rt);

        // create PeerConnection
        const peer = try PeerConnection.init(self.allocator, socket, username, self.own_username.?, token, connection_type);
        errdefer peer.deinit(rt);

        // add to peer map
        self.peers_mutex.lock();
        try self.peers.put(peer.username, peer);
        self.peers_mutex.unlock();

        return peer;
    }

    // Spawns peer and begins running.
    fn spawnPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, we_initiated: bool) !void {
        if (self.peer_group) |group| {
            try group.spawn(rt, runPeer, .{ self, rt, peer, we_initiated });
        } else {
            return error.NotConnected;
        }
    }

    // Runs the peer.
    fn runPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, we_initiated: bool) void {
        defer {
            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();
            _ = self.peers.remove(peer.username);
        }
        peer.run(rt, we_initiated);
    }

    // Sends a message to the connected server.
    fn sendMessage(self: *Client, rt: *zio.Runtime, msg: messages.Message) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;

        // write message & flush
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Reads a message from the connected server.
    fn readResponse(self: *Client, reader: *zio.net.Stream.Reader) !messages.Response {
        // TODO: handle error when socket is closed

        // parse message header
        const payload_len = try reader.interface.takeInt(u32, .little);
        const message_code = try reader.interface.takeInt(u32, .little);

        // handoff to relevant parser
        return switch (message_code) {
            1 => .{ .login = try messages.LoginResponse.parse(&reader.interface, self.allocator, payload_len) },
            3 => .{ .getPeerAddress = try messages.GetPeerAddressResponse.parse(&reader.interface, self.allocator) },
            18 => .{ .connectToPeer = try messages.ConnectToPeerResponse.parse(&reader.interface, self.allocator) },
            22 => .{ .messageUser = try messages.MessageUserResponse.parse(&reader.interface, self.allocator) },
            64 => .{ .roomList = try messages.RoomListResponse.parse(&reader.interface, self.allocator) },
            69 => .{ .privilegedUsers = try messages.PrivilegedUsersResponse.parse(&reader.interface, self.allocator) },
            83 => .{ .parentMinSpeed = try messages.ParentMinSpeedResponse.parse(&reader.interface) },
            84 => .{ .parentSpeedRatio = try messages.ParentSpeedRatioResponse.parse(&reader.interface) },
            104 => .{ .wishlistSearch = try messages.WishlistSearchResponse.parse(&reader.interface) },
            160 => .{ .excludedSearchPhrases = try messages.ExcludedSearchPhrasesResponse.parse(&reader.interface, self.allocator) },
            else => {
                std.log.warn("server readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

                // discard remaining unknown message bytes
                const remaining: usize = payload_len - 4;
                try reader.interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }
};

pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    own_username: []const u8,
    token: u32,
    connection_type: types.ConnectionType,
    socket: zio.net.Stream,

    // oneshot channels for request-response
    user_info_channel: ?*zio.Channel(messages.UserInfoMessage) = null,

    // mutex for channel access
    channels_mutex: std.Thread.Mutex = .{},

    // connection state
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected),

    pub fn init(allocator: std.mem.Allocator, socket: zio.net.Stream, username: []const u8, own_username: []const u8, token: u32, connection_type: types.ConnectionType) !*PeerConnection {
        const pc = try allocator.create(PeerConnection);
        pc.* = .{
            .allocator = allocator,
            .socket = socket,
            .username = try allocator.dupe(u8, username),
            .own_username = try allocator.dupe(u8, own_username),
            .token = token,
            .connection_type = connection_type,
            .connection_state = std.atomic.Value(ConnectionState).init(.connecting),
        };
        return pc;
    }

    pub fn deinit(self: *PeerConnection, rt: *zio.Runtime) void {
        self.connection_state.store(.disconnected, .seq_cst);
        self.allocator.free(self.username);
        self.allocator.free(self.own_username);
        self.socket.close(rt);
    }

    // Self-contained peer connection logic.
    pub fn run(self: *PeerConnection, rt: *zio.Runtime, we_initiated: bool) void {
        defer self.deinit(rt);

        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.reader(rt, &read_buf);

        // send correct handshake
        if (we_initiated) {
            const msg = messages.PeerInit{
                .username = self.own_username,
                .type = @tagName(self.connection_type),
                .token = 0,
            };

            self.sendPeerInitMessage(rt, .{ .peerInit = msg }) catch |err| {
                std.log.err("Failed to send PeerInit to {s}: {}", .{ self.username, err });
                return;
            };
        } else {
            const msg = messages.PierceFireWall{
                .token = self.token,
            };

            self.sendPeerInitMessage(rt, .{ .pierceFireWall = msg }) catch |err| {
                std.log.err("Failed to send PierceFirewall to {s}: {}", .{ self.username, err });
                return;
            };
        }

        // handshake done, good to go
        std.log.debug("Handshake complete with {s}, beginning read loop", .{self.username});
        self.connection_state.store(.connected, .seq_cst);

        // begin read loop
        self.readLoop(rt, &reader);
    }

    // Gets the connected peer's user info.
    pub fn getUserInfo(self: *PeerConnection, rt: *zio.Runtime) !messages.UserInfoMessage {
        // wait for handshake
        while (self.connection_state.load(.seq_cst) != .connected) {
            try rt.sleep(.fromMilliseconds(1));
        }

        // create oneshot channel for request-response
        var one: [1]messages.UserInfoMessage = undefined;
        var channel = zio.Channel(messages.UserInfoMessage).init(&one);
        defer channel.close(.graceful);

        // register
        self.channels_mutex.lock();
        self.user_info_channel = &channel;
        self.channels_mutex.unlock();

        // unregister on exit
        defer {
            self.channels_mutex.lock();
            self.user_info_channel = null;
            self.channels_mutex.unlock();
        }

        // request user info
        try self.sendPeerMessage(rt, .{ .getUserInfo = .{} });

        // block until we receive a response
        return channel.receive(rt);
    }

    // Peer message handler.
    fn readResponse(self: *PeerConnection, reader: *zio.net.Stream.Reader) !messages.PeerMessage {
        // TODO: handle error when socket is closed

        // parse message header
        const payload_len = try reader.interface.takeInt(u32, .little);
        const start_seek = reader.interface.seek; // current_seek - start_seek < payload_len, keep parsing
        const message_code = try reader.interface.takeInt(u32, .little);

        // handoff to relevant parser
        return switch (message_code) {
            4 => .{ .getSharedFileList = try messages.EmptyMessage.parse(self.allocator, &reader.interface) },
            5 => .{ .sharedFileList = try messages.SharedFileListMessage.parse(self.allocator, &reader.interface) },
            15 => .{ .getUserInfo = try messages.EmptyMessage.parse(self.allocator, &reader.interface) },
            16 => .{ .userInfo = try messages.UserInfoMessage.parse(self.allocator, &reader.interface, start_seek, payload_len) },
            else => {
                std.log.warn("Peer readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

                // discard
                const remaining: usize = payload_len - 4;
                try reader.interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }

    // Peer read loop.
    fn readLoop(self: *PeerConnection, rt: *zio.Runtime, reader: *zio.net.Stream.Reader) void {
        while (self.connection_state.load(.seq_cst) == .connected) {
            var message = self.readResponse(reader) catch |err| {
                if (err == error.EndOfStream) {
                    std.log.debug("Peer {s} disconnected", .{self.username});
                    return;
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
                    self.sendPeerMessage(rt, .{ .sharedFileList = msg }) catch |err| {
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
                    self.sendPeerMessage(rt, .{ .userInfo = msg }) catch |err| {
                        std.log.err("Failed sending user info: {}", .{err});
                        continue;
                    };
                    std.log.debug("Sent {s} our user info", .{self.username});
                },
                .userInfo => |msg| {
                    std.log.debug("\tReceived {s}'s user info", .{self.username});
                    should_deinit = false;

                    // send response in oneshot channel, if someone is waiting
                    if (self.user_info_channel) |channel| {
                        channel.send(rt, msg) catch |err| {
                            std.log.debug("Error sending user info response in oneshot channel: {}", .{err});
                        };
                    }
                },
            }
        }
    }

    // Sends one of the PeerInit messages: PierceFireWall or PeerInit.
    fn sendPeerInitMessage(self: *PeerConnection, rt: *zio.Runtime, msg: messages.PeerInitMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Sends a PeerMessage to the peer.
    fn sendPeerMessage(self: *PeerConnection, rt: *zio.Runtime, msg: messages.PeerMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }
};
