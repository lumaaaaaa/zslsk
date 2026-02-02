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
    rt: ?*zio.Runtime, // async I/O runtime
    thread: ?std.Thread, // background thread for library
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected), // connection state
    socket: ?zio.net.Stream, // socket connection to centralized server
    p2p_server: ?zio.net.Server, // server listening for p2p connections
    peers: std.StringHashMap(*PeerConnection), // established peer connections
    peers_mutex: std.Thread.Mutex = .{},

    // key-based request-response waiters
    user_info_waiters: std.StringHashMap(*zio.Channel(messages.UserInfoMessage)),
    get_peer_address_waiters: std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)),
    waiter_mutex: std.Thread.Mutex = .{},

    /// Exported Library Functions ///
    pub fn init(allocator: std.mem.Allocator) !Client {
        return .{
            .allocator = allocator,
            .rt = null,
            .thread = null,
            .socket = null,
            .p2p_server = null,
            .peers = std.StringHashMap(*PeerConnection).init(allocator),
            .user_info_waiters = std.StringHashMap(*zio.Channel(messages.UserInfoMessage)).init(allocator),
            .get_peer_address_waiters = std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        // disconnect
        self.connection_state.store(.disconnected, .seq_cst);
        if (self.rt) |rt| rt.deinit();

        // join background thread
        if (self.thread) |t| t.join();
    }

    /// Connects and authenticates with a Soulseek server. Begins the async runtime on a background thread.
    pub fn connect(self: *Client, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
        self.thread = try std.Thread.spawn(.{}, backgroundThread, .{ self, hostname, port, username, password, listen_port });
    }

    /// TODO: make this work (eventually) blocked by p2p
    pub fn getUserInfo(self: *Client, username: []const u8) !messages.UserInfoMessage {
        // create oneshot channel for username
        var one: [1]messages.UserInfoMessage = undefined;
        var channel = zio.Channel(messages.UserInfoMessage).init(&one);
        defer channel.close(.immediate); // FIX: .immediate may cause problems i do not know

        // add channel to user info waiter map
        self.waiter_mutex.lock();
        try self.user_info_waiters.put(username, &channel); // clobbers existing
        self.waiter_mutex.unlock();

        // defer waiter map cleanup
        defer {
            self.waiter_mutex.lock();
            defer self.waiter_mutex.unlock();
            _ = self.user_info_waiters.remove(username);
        }

        // send user info request
        //const get_peer_address_msg = messages.UserInfoMessage{

        //};
        //try self.sendMessage(.{ .getPeerAddress = get_peer_address_msg });

        // receive response
        //const get_peer_address_resp = try channel.receive(self.rt);

        //return messages.UserInfoMessage{
        //    .description = get_peer_address_resp.description,
        //    .picture = "",
        //    .queue_size = get_peer_address_resp,
        //    .slots_free = false,
        //    .total_upload = 0,
        //    .upload_permitted = get_peer_address_resp.,
        //};
        return messages.UserInfoMessage{
            .description = "",
            .picture = "",
            .queue_size = 0,
            .slots_free = true,
            .total_upload = 0,
            .upload_permitted = .everyone,
        };
    }

    /// Internal Library Functions ///
    // Background thread hosting the Zio runtime.
    fn backgroundThread(self: *Client, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
        // init zio runtime
        var rt = zio.Runtime.init(self.allocator, .{
            .thread_pool = .{},
        }) catch |err| {
            std.log.err("Failed to init runtime: {}", .{err});
            self.connection_state.store(.failed, .seq_cst);
            return;
        };
        defer rt.deinit();

        self.rt = rt;
        defer {
            self.rt = null;
        }

        // dispatch main task
        var task = self.rt.?.spawn(mainTask, .{ self, hostname, port, username, password, listen_port }) catch |err| {
            std.log.err("Failed to spawn: {}", .{err});
            self.connection_state.store(.failed, .seq_cst);
            return;
        };

        // if the task completes, we have been disconnected from the server
        task.join(self.rt.?) catch {};
        task.getResult() catch |err| {
            std.log.err("Main task exited with error: {}", .{err});
        };

        self.connection_state.store(.disconnected, .seq_cst);
        std.log.err("Disconnected from server.", .{});
    }

    // Main task executed by the Zio runtime.
    fn mainTask(self: *Client, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
        // connect to server
        std.log.debug("Establishing TCP connection to host {s}:{d}...", .{ hostname, port });
        self.socket = try zio.net.tcpConnectToHost(self.rt.?, hostname, port, .{ .timeout = .none });
        std.log.debug("TCP connection successful.", .{});

        // initialize socket reader and writer
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.?.reader(self.rt.?, &read_buf);

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
        std.log.debug("Reading login response from server...", .{});
        var login_response = try self.readResponse(&reader);
        defer login_response.deinit(self.allocator);

        if (!login_response.login.success) {
            std.log.err("Login failed: {s}", .{login_response.login.rejection_reason.?});
            return error.LoginFailed;
        } else {
            std.log.debug("Login successful. {s}", .{login_response.login.greeting.?});
        }

        // listen for p2p connections
        const listen_addr = try zio.net.IpAddress.parseIp4("0.0.0.0", listen_port);
        self.p2p_server = try listen_addr.listen(self.rt.?, .{});
        std.log.debug("Listening for P2P connections on client public IPv4: {d}.{d}.{d}.{d}:{d}", .{
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

        std.log.debug("Sending message to advertise P2P port...", .{});
        try self.sendMessage(.{ .setWaitPort = set_wait_port_msg });
        std.log.debug("Advertised P2P port successfully.", .{});

        // we're connected!
        self.connection_state.store(.connected, .seq_cst);

        // dispatch concurrent tasks
        var group: zio.Group = .init;
        defer group.cancel(self.rt.?);

        try group.spawn(self.rt.?, p2pListenerTask, .{self}); // p2p listener

        // begin read loop
        self.readLoop(&reader);
    }

    // P2P listener.
    fn p2pListenerTask(self: *Client) void {
        var peer_group: zio.Group = .init;
        defer peer_group.cancel(self.rt.?);

        while (self.connection_state.load(.seq_cst) == .connected) {
            const stream = self.p2p_server.?.accept(self.rt.?) catch |err| {
                std.log.warn("P2P accept error: {}", .{err});
                continue;
            };
            errdefer stream.close(self.rt.?);

            std.log.debug("Incoming P2P connection from {f}", .{stream.socket.address});
            //try peer_group.spawn(rt, handleIncomingPeer, .{ self, rt, stream });
        }
    }

    // Server read loop.
    fn readLoop(self: *Client, reader: *zio.net.Stream.Reader) void {
        // group for synchronous operations
        var group: zio.Group = .init;
        defer group.cancel(self.rt.?);

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
                    if (self.get_peer_address_waiters.get(resp.username)) |channel| {
                        channel.send(self.rt.?, resp) catch |err| {
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

                    group.spawn(self.rt.?, handleConnectToPeer, .{ self, resp }) catch |err| {
                        std.log.err("Could not spawn thread to handle ConnectToPeer message: {}", .{err});
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

    // Message handler for ConnectToPeer, establishes an indirect peer connection.
    fn handleConnectToPeer(self: *Client, resp: messages.ConnectToPeerResponse) void {
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
                std.log.debug("Establishing indirect P connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
                    msg.username,
                    msg.ip[0],
                    msg.ip[1],
                    msg.ip[2],
                    msg.ip[3],
                    msg.port,
                });

                // connect to host
                const address = zio.net.IpAddress.initIp4(msg.ip, @intCast(msg.port));
                const socket = zio.net.tcpConnectToAddress(self.rt.?, address, .{ .timeout = .{ .duration = .fromSeconds(20) } }) catch |err| { // TODO: move connect timeout to constant
                    std.log.err("Timed out when connecting to peer: {}", .{err});
                    return;
                };

                // create PeerConnection
                const peer = PeerConnection.init(self.allocator, self.rt.?, socket, msg.username, msg.token, conn_type) catch |err| {
                    std.log.err("Could not initialize PeerConnection: {}", .{err});
                    return;
                };

                // add to peer map
                self.peers_mutex.lock();
                self.peers.put(peer.username, peer) catch |err| {
                    std.log.err("Could not add PeerConnection to peers map: {}", .{err});
                };
                self.peers_mutex.unlock();

                // run peer and block
                peer.run(true);
            },
            types.ConnectionType.F => {
                // file transfer
            },
            types.ConnectionType.D => {
                // distributed network
            },
        }
    }

    // Sends a message to the connected server.
    fn sendMessage(self: *Client, msg: messages.Message) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(self.rt.?, &write_buf);
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
    rt: *zio.Runtime,
    username: []const u8,
    token: u32,
    connection_type: types.ConnectionType,
    socket: zio.net.Stream,

    // key-based request-response waiters
    user_info_channel: ?*zio.Channel(messages.UserInfoMessage) = null,

    // mutex for channel access
    channels_mutex: std.Thread.Mutex = .{},

    // connection state
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected),

    pub fn init(allocator: std.mem.Allocator, rt: *zio.Runtime, socket: zio.net.Stream, username: []const u8, token: u32, connection_type: types.ConnectionType) !*PeerConnection {
        const pc = try allocator.create(PeerConnection);
        pc.* = .{
            .allocator = allocator,
            .rt = rt,
            .socket = socket,
            .username = try allocator.dupe(u8, username),
            .token = token,
            .connection_type = connection_type,
            .connection_state = std.atomic.Value(ConnectionState).init(.connecting),
        };
        return pc;
    }

    pub fn deinit(self: *PeerConnection) void {
        self.connection_state.store(.disconnected, .seq_cst);
        self.allocator.free(self.username);
        self.socket.close(self.rt);
    }

    // Self-contained peer connection logic.
    pub fn run(self: *PeerConnection, we_initiated: bool) void {
        defer self.deinit();

        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.reader(self.rt, &read_buf);

        // send correct handshake
        if (we_initiated) {
            const msg = messages.PierceFireWall{
                .token = self.token,
            };

            self.sendPeerInitMessage(.{ .pierceFireWall = msg }) catch |err| {
                std.log.err("Failed to send PierceFirewall to {s}: {}", .{ self.username, err });
                return;
            };
        } else {
            const msg = messages.PeerInit{
                .username = self.username,
                .type = @tagName(self.connection_type),
            };

            self.sendPeerInitMessage(.{ .peerInit = msg }) catch |err| {
                std.log.err("Failed to send PeerInit to {s}: {}", .{ self.username, err });
                return;
            };
        }

        // begin read loop
        self.readLoop(&reader);
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
    fn readLoop(self: *PeerConnection, reader: *zio.net.Stream.Reader) void {
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
                    // TODO: respond in corresponding oneshot
                    _ = msg;
                },
            }
        }
    }

    // Sends one of the PeerInit messages: PierceFireWall or PeerInit.
    fn sendPeerInitMessage(self: *PeerConnection, msg: messages.PeerInitMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.writer(self.rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Sends a PeerMessage to the peer.
    fn sendPeerMessage(self: *PeerConnection, msg: messages.PeerMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.writer(self.rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }
};
