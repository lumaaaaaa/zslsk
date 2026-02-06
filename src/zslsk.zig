const std = @import("std");
pub const messages = @import("messages.zig");
const types = @import("types.zig");
const zio = @import("zio");

pub const ConnectionState = enum(u8) {
    disconnected,
    connecting,
    connected,
    failed,
};

pub const SearchChannel = struct {
    token: u32,
    channel: *zio.Channel(messages.FileSearchResponseMessage),
    buffer: []messages.FileSearchResponseMessage,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected), // connection state
    socket: ?zio.net.Stream, // socket connection to centralized server
    p2p_server: ?zio.net.Server, // server listening for p2p connections
    peers: std.StringHashMap(*PeerConnection), // established peer connections
    peers_mutex: std.Thread.Mutex = .{},
    own_username: ?[]const u8,
    connected_peer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // group for peer task execution
    peer_group: zio.Group = .init,

    // oneshot channels for request-response, keyed by username for concurrency
    get_peer_address_channels: std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)),
    waiters_mutex: std.Thread.Mutex = .{},

    // channels for streaming request-response
    search_result_channels: std.AutoHashMap(u32, SearchChannel),
    search_mutex: std.Thread.Mutex = .{},

    /// Exported Library Functions ///
    pub fn init(allocator: std.mem.Allocator) !Client {
        return .{
            .allocator = allocator,
            .socket = null,
            .p2p_server = null,
            .peers = .init(allocator),
            .own_username = null,
            .get_peer_address_channels = .init(allocator),
            .search_result_channels = .init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.own_username) |username| self.allocator.free(username);
        self.get_peer_address_channels.deinit();

        var search_iter = self.search_result_channels.iterator();
        while (search_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.buffer);
            self.allocator.destroy(entry.value_ptr.channel);
        }
        self.search_result_channels.deinit();

        self.peers.deinit();
    }

    pub fn disconnect(self: *Client, rt: *zio.Runtime) void {
        // disconnect (this should cascade and shut down loops)
        self.connection_state.store(.disconnected, .seq_cst);

        // shut down our connections
        if (self.socket) |s| s.close(rt);
        if (self.p2p_server) |s| s.close(rt);

        // close searches
        self.search_mutex.lock();
        var search_iter = self.search_result_channels.iterator();
        while (search_iter.next()) |channel| {
            channel.value_ptr.*.channel.close(.graceful);
        }
        self.search_mutex.unlock();
    }

    /// Connects and authenticates with a Soulseek server. Begins the async runtime.
    pub fn run(self: *Client, rt: *zio.Runtime, hostname: []const u8, port: u16, username: []const u8, password: []const u8, listen_port: u16) !void {
        // store own username
        self.own_username = try self.allocator.dupe(u8, username);

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
        try self.peer_group.spawn(rt, p2pListenerTask, .{ self, rt, listen_port }); // p2p listener

        // begin read loop
        self.readLoop(rt, &reader);

        // shutdown peers
        self.peers_mutex.lock();
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.connection_state.store(.disconnected, .seq_cst);
            if (entry.value_ptr.*.socket) |s| {
                s.close(rt);
                entry.value_ptr.*.socket = null;
            }
        }
        self.peers_mutex.unlock();

        self.peer_group.cancel(rt);
    }

    /// Gets user info of the user with the specified username.
    pub fn getUserInfo(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.UserInfoMessage {
        // get the peer
        const conn = try self.getOrCreatePeer(rt, username);

        // get user info
        return try conn.getUserInfo(rt);
    }

    /// Gets shared file list of the user with the specified username.
    pub fn getSharedFileList(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.SharedFileListMessage {
        // get the peer
        const peer = try self.getOrCreatePeer(rt, username);

        // get user info
        return try peer.getSharedFileList(rt);
    }

    /// Searches network for files matching a specified query.
    pub fn fileSearch(self: *Client, rt: *zio.Runtime, query: []const u8) !SearchChannel {
        // zig new std.Io to access std.Io.random
        var threaded = std.Io.Threaded.init(self.allocator, .{
            .environ = .empty,
        }); // FIX: this is improper use of Zig's new std.Io. beyond that, it's also a mess and I hate it.
        defer threaded.deinit();
        const io = threaded.ioBasic();

        // generate a random token to track the search
        var token: u32 = undefined;
        io.random(std.mem.asBytes(&token));

        // create a channel for the search results (backed by 256 FileSearchResponseMessages)
        const buf = try self.allocator.alloc(messages.FileSearchResponseMessage, 256);
        errdefer self.allocator.free(buf);
        const channel = try self.allocator.create(zio.Channel(messages.FileSearchResponseMessage));
        errdefer self.allocator.destroy(channel);
        channel.* = zio.Channel(messages.FileSearchResponseMessage).init(buf);

        // wrap channel as SearchChannel
        const search_channel = SearchChannel{
            .token = token,
            .channel = channel,
            .buffer = buf,
        };

        // register channel in search map
        self.search_mutex.lock();
        try self.search_result_channels.put(token, search_channel);
        self.search_mutex.unlock();

        // execute search on centralized server
        const file_search_msg = messages.FileSearchMessage{
            .token = token,
            .query = query,
        };
        try self.sendMessage(rt, .{ .fileSearch = file_search_msg });

        return search_channel;
    }

    /// Requests a specified file from the peer with specified username.
    pub fn downloadFile(self: *Client, rt: *zio.Runtime, username: []const u8, filename: []const u8) !void {
        // get the peer
        const peer = try self.getOrCreatePeer(rt, username);

        // request download
        try peer.queueDownload(rt, filename);
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
        const listen_addr = zio.net.IpAddress.parseIp4("0.0.0.0", listen_port) catch |err| {
            std.log.err("P2P listener failed to parse address: {}", .{err});
            return;
        };
        self.p2p_server = listen_addr.listen(rt, .{}) catch |err| {
            std.log.err("P2P listener failed to listen: {}", .{err});
            return;
        };
        std.log.debug("Listening for P2P connections on port {d}", .{
            listen_port,
        });

        // advertise port to server
        const set_wait_port_msg = messages.SetWaitPortMessage{
            .port = listen_port,
        };

        std.log.debug("Sending message to advertise P2P port...", .{});
        self.sendMessage(rt, .{ .setWaitPort = set_wait_port_msg }) catch |err| {
            std.log.err("P2P listener failed to advertise listen port: {}", .{err});
            return;
        };
        std.log.debug("Advertised P2P port successfully.", .{});

        while (self.connection_state.load(.seq_cst) == .connected) {
            const stream = self.p2p_server.?.accept(rt) catch |err| {
                std.log.warn("P2P accept error: {}", .{err});
                continue;
            };
            errdefer stream.close(rt);

            std.log.debug("Incoming P2P connection from {f}", .{stream.socket.address});
            stream.close(rt);
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
                .login => {}, // do nothing, we handle logins just once, synchronously on connect
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

                    self.peer_group.spawn(rt, handleConnectToPeer, .{ self, rt, resp }) catch |err| {
                        std.log.err("Could not spawn thread to handle ConnectToPeer message: {}", .{err});
                    };
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
                .roomList => |resp| std.log.debug("\tRoom counts: {d} total, {d} owned private, {d} unowned private, {d} operated private", .{ resp.rooms.len, resp.owned_private_rooms.len, resp.unowned_private_rooms.len, resp.operated_private_rooms.len }),
                .privilegedUsers => |resp| std.log.debug("\tPrivileged user count: {d}", .{resp.users.len}), // just print for now
                .parentMinSpeed => |resp| std.log.debug("\tMinimum upload speed to become parent: {d}", .{resp.speed}), // just print for now
                .parentSpeedRatio => |resp| std.log.debug("\tParent speed ratio: {d}", .{resp.ratio}), // just print for now
                .wishlistSearch => |resp| std.log.debug("\tWishlist search interval: {d} seconds", .{resp.interval}), // just print for now
                .excludedSearchPhrases => |resp| std.log.debug("\tExcluded search phrase count: {d}", .{resp.phrases.len}), // TODO: store these phrases, search requests should exclude paths containing these strings
            }
        }
    }

    // Message handler for ConnectToPeer, establishes an indirect peer connection.
    fn handleConnectToPeer(self: *Client, rt: *zio.Runtime, resp: messages.ConnectToPeerResponse) void {
        var msg = resp;
        defer msg.deinit(self.allocator);

        // TODO: handle different connection types
        const connection_type = std.meta.stringToEnum(types.ConnectionType, msg.type);
        switch (connection_type.?) {
            // p2p
            types.ConnectionType.P => |conn_type| {
                self.peers_mutex.lock();
                const peer_gop = self.peers.getOrPut(msg.username) catch |err| {
                    std.log.err("Error getting peer: {}", .{err});
                    return;
                };
                if (peer_gop.found_existing) {
                    // peer with username exists
                    self.peers_mutex.unlock();
                    return;
                }

                // new peer
                const peer = PeerConnection.init(self.allocator, self, msg.username, self.own_username.?, msg.token, conn_type) catch |err| {
                    std.log.err("Error initializing peer: {}", .{err});
                    _ = self.peers.remove(msg.username);
                    self.peers_mutex.unlock();
                    return;
                };

                // update hashmap ptrs before releasing lock
                peer_gop.key_ptr.* = peer.username; // update key to peer owned memory
                peer_gop.value_ptr.* = peer;
                self.peers_mutex.unlock();

                // connect to peer
                peer.connect(rt, msg.ip, @intCast(msg.port)) catch |err| {
                    // cancellations and timeouts are normal behavior, no need to print anything
                    if (err != error.Canceled and err != error.Timeout) {
                        std.log.err("Error connecting to peer: {}", .{err});
                    }

                    self.peers_mutex.lock();
                    _ = self.peers.remove(msg.username);
                    self.peers_mutex.unlock();
                    peer.deinit(rt); // peer is not yet running, deinit
                    self.allocator.destroy(peer);
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
    fn getOrCreatePeer(self: *Client, rt: *zio.Runtime, username: []const u8) !*PeerConnection {
        self.peers_mutex.lock();
        const peer_gop = try self.peers.getOrPut(username);
        if (peer_gop.found_existing) {
            // peer with username exists
            self.peers_mutex.unlock();
            return peer_gop.value_ptr.*;
        }

        // new peer
        const peer = PeerConnection.init(self.allocator, self, username, self.own_username.?, 0, .P) catch |err| {
            _ = self.peers.remove(username);
            self.peers_mutex.unlock();
            return err;
        };

        // update hashmap ptrs before releasing lock
        peer_gop.key_ptr.* = peer.username; // update key to peer owned memory
        peer_gop.value_ptr.* = peer;
        self.peers_mutex.unlock();

        // resolve peer address
        var get_peer_address_resp = self.getPeerAddress(rt, username) catch |err| {
            self.peers_mutex.lock();
            _ = self.peers.remove(username);
            self.peers_mutex.unlock();
            peer.deinit(rt); // peer is not yet running, deinit
            self.allocator.destroy(peer);
            return err;
        };
        defer get_peer_address_resp.deinit(self.allocator);

        // connect to peer
        peer.connect(rt, get_peer_address_resp.ip, @intCast(get_peer_address_resp.port)) catch |err| {
            self.peers_mutex.lock();
            _ = self.peers.remove(username);
            self.peers_mutex.unlock();
            peer.deinit(rt); // peer is not yet running, deinit
            self.allocator.destroy(peer);
            return err;
        };

        // spawn peer and run
        try self.spawnPeer(rt, peer, true);

        return peer;
    }

    // Spawns peer and begins running.
    fn spawnPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, we_initiated: bool) !void {
        try self.peer_group.spawn(rt, runPeer, .{ self, rt, peer, we_initiated });
    }

    // Runs the peer.
    fn runPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, we_initiated: bool) void {
        peer.run(rt, we_initiated);

        // cleanup
        self.peers_mutex.lock();
        _ = self.peers.remove(peer.username);
        std.log.debug("Peer '{s}' disconnected. There are now {d} active P2P connections.", .{ peer.username, self.connected_peer_count.load(.seq_cst) });
        self.peers_mutex.unlock();
        peer.deinit(rt);
        self.allocator.destroy(peer);
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
                std.log.warn("Server readResponse dropped an unknown message. code: {d}, length: {d}", .{ message_code, payload_len });

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
    client: *Client,
    username: []const u8,
    own_username: []const u8,
    token: u32,
    connection_type: types.ConnectionType,
    socket: ?zio.net.Stream,

    // oneshot channels for request-response
    user_info_channel: ?*zio.Channel(messages.UserInfoMessage) = null,
    shared_file_list_channel: ?*zio.Channel(messages.SharedFileListMessage) = null,
    transfer_request_channel: ?*zio.Channel(messages.TransferRequestMessage) = null,

    // mutex for channel access
    channels_mutex: std.Thread.Mutex = .{},

    // connection state
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected),

    pub fn init(allocator: std.mem.Allocator, client: *Client, username: []const u8, own_username: []const u8, token: u32, connection_type: types.ConnectionType) !*PeerConnection {
        const pc = try allocator.create(PeerConnection);
        pc.* = .{
            .allocator = allocator,
            .client = client,
            .socket = null,
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
        if (self.socket) |s| s.close(rt);
        if (self.user_info_channel) |c| c.close(.graceful);
        if (self.shared_file_list_channel) |c| c.close(.graceful);
    }

    pub fn connect(self: *PeerConnection, rt: *zio.Runtime, ip: [4]u8, port: u16) !void {
        std.log.debug("Establishing {s} connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
            @tagName(self.connection_type),
            self.username,
            ip[0],
            ip[1],
            ip[2],
            ip[3],
            port,
        });

        // connect to host
        const address = zio.net.IpAddress.initIp4(ip, port);
        self.socket = try zio.net.tcpConnectToAddress(rt, address, .{
            .timeout = .{ .duration = .fromSeconds(20) },
        });
    }

    // Self-contained peer connection logic.
    pub fn run(self: *PeerConnection, rt: *zio.Runtime, we_initiated: bool) void {
        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.?.reader(rt, &read_buf);

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

        // update metrics in our client
        _ = self.client.connected_peer_count.fetchAdd(1, .seq_cst);
        defer _ = self.client.connected_peer_count.fetchSub(1, .seq_cst);

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

    // Gets the connected peer's shared file list.
    pub fn getSharedFileList(self: *PeerConnection, rt: *zio.Runtime) !messages.SharedFileListMessage {
        // wait for handshake
        while (self.connection_state.load(.seq_cst) != .connected) {
            try rt.sleep(.fromMilliseconds(1));
        }

        // create oneshot channel for request-response
        var one: [1]messages.SharedFileListMessage = undefined;
        var channel = zio.Channel(messages.SharedFileListMessage).init(&one);
        defer channel.close(.graceful);

        // register
        self.channels_mutex.lock();
        self.shared_file_list_channel = &channel;
        self.channels_mutex.unlock();

        // unregister on exit
        defer {
            self.channels_mutex.lock();
            self.shared_file_list_channel = null;
            self.channels_mutex.unlock();
        }

        // request user info
        try self.sendPeerMessage(rt, .{ .getSharedFileList = .{} });

        // block until we receive a response
        return channel.receive(rt);
    }

    pub fn queueDownload(self: *PeerConnection, rt: *zio.Runtime, filename: []const u8) !void {
        // wait for handshake
        while (self.connection_state.load(.seq_cst) != .connected) {
            try rt.sleep(.fromMilliseconds(1));
        }

        // create oneshot channel for request-response
        var one: [1]messages.TransferRequestMessage = undefined;
        var channel = zio.Channel(messages.TransferRequestMessage).init(&one);
        defer channel.close(.graceful);

        // register
        self.channels_mutex.lock();
        self.transfer_request_channel = &channel;
        self.channels_mutex.unlock();

        // unregister on exit
        defer {
            self.channels_mutex.lock();
            self.transfer_request_channel = null;
            self.channels_mutex.unlock();
        }

        // ask peer to queue download
        try self.sendPeerMessage(rt, .{ .queueUpload = .{ .filename = filename } });

        // block until we receive a transfer response
        var transfer_request_msg = try channel.receive(rt);
        defer transfer_request_msg.deinit(self.allocator);

        // respond to transfer response
        const transfer_response_msg = messages.TransferResponseMessage{
            .token = transfer_request_msg.token,
            .allowed = true,
            .size = 0,
            .reason = null,
            .direction = .uploadToPeer,
        };
        try self.sendPeerMessage(rt, .{ .transferResponse = transfer_response_msg });
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
            5 => .{ .sharedFileList = try messages.SharedFileListMessage.parse(self.allocator, &reader.interface, payload_len) },
            9 => .{ .fileSearchResponse = try messages.FileSearchResponseMessage.parse(self.allocator, &reader.interface, payload_len) },
            15 => .{ .getUserInfo = try messages.EmptyMessage.parse(self.allocator, &reader.interface) },
            16 => .{ .userInfo = try messages.UserInfoMessage.parse(self.allocator, &reader.interface, start_seek, payload_len) },
            40 => .{ .transferRequest = try messages.TransferRequestMessage.parse(self.allocator, &reader.interface) },
            43 => .{ .queueUpload = try messages.QueueUploadMessage.parse(self.allocator, &reader.interface) },
            46 => .{ .uploadFailed = try messages.UploadFailedMessage.parse(self.allocator, &reader.interface) },
            else => {
                std.log.warn("Peer {s} readResponse dropped an unknown message. code: {d}, length: {d}", .{ self.username, message_code, payload_len });

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
                if (err == error.EndOfStream or err == error.ReadFailed) {
                    self.connection_state.store(.disconnected, .seq_cst);
                    return;
                }
                std.log.err("Error encountered in peer readResponse: {}", .{err});
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

                    const files = self.allocator.alloc(messages.SharedFile, 1) catch continue;
                    defer self.allocator.free(files);
                    files[0] = .{
                        .code = 1,
                        .name = "hello_world.zig",
                        .size = 420,
                        .extension = "zig",
                        .attributes = &[_]messages.FileAttributes{},
                    };

                    const dirs = self.allocator.alloc(messages.SharedDirectory, 1) catch continue;
                    defer self.allocator.free(dirs);
                    dirs[0] = .{
                        .name = "zslsk\\files",
                        .files = files,
                    };

                    const msg = messages.SharedFileListMessage{
                        .directories = dirs,
                        .private_directories = &[_]messages.SharedDirectory{},
                    };

                    // send shared file list to peer
                    self.sendPeerMessage(rt, .{ .sharedFileList = msg }) catch |err| {
                        std.log.err("\tFailed sending file list: {}", .{err});
                        continue;
                    };
                    std.log.debug("\tSent {s} our file list", .{self.username});
                },
                .sharedFileList => |msg| {
                    std.log.debug("\tReceived {s}'s file list", .{self.username});

                    // if someone is waiting, send response in oneshot channel
                    if (self.shared_file_list_channel) |channel| {
                        should_deinit = false;
                        channel.send(rt, msg) catch |err| {
                            std.log.err("\tError sending shared file list response in oneshot channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .fileSearchResponse => |msg| {
                    std.log.debug("\tReceived {s}'s file search response for our query {d}", .{ self.username, msg.token });

                    // get corresponding search channel
                    self.client.search_mutex.lock();
                    const search_channel = self.client.search_result_channels.get(msg.token);
                    self.client.search_mutex.unlock();

                    // if channel exists, send response
                    if (search_channel) |s| {
                        should_deinit = false; // responsibility of receiver to deinit the response
                        s.channel.send(rt, msg) catch |err| {
                            std.log.err("\tError sending file search response in channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .getUserInfo => {
                    std.log.debug("\t{s} requests our user info", .{self.username});

                    const msg = messages.UserInfoMessage{
                        .description = "hello from zslsk",
                        .picture = null,
                        .queue_size = 0,
                        .slots_free = true,
                        .total_upload = 420,
                        .upload_permitted = .everyone,
                    };

                    self.sendPeerMessage(rt, .{ .userInfo = msg }) catch |err| {
                        std.log.err("\tFailed sending user info: {}", .{err});
                        continue;
                    };
                    std.log.debug("\tSent {s} our user info", .{self.username});
                },
                .userInfo => |msg| {
                    std.log.debug("\tReceived {s}'s user info", .{self.username});
                    should_deinit = false;

                    // send response in oneshot channel, if someone is waiting
                    if (self.user_info_channel) |channel| {
                        channel.send(rt, msg) catch |err| {
                            std.log.err("\tError sending user info response in oneshot channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .transferRequest => |msg| {
                    std.log.debug("\tReceived transfer request from {s}: {s} | {s} | {d}", .{ self.username, @tagName(msg.direction), msg.filename, msg.size });
                    should_deinit = false;

                    // send request in oneshot channel, if someone is waiting
                    if (self.transfer_request_channel) |channel| {
                        channel.send(rt, msg) catch |err| {
                            std.log.err("\tError sending transfer response in oneshot channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .transferResponse => |msg| {
                    std.log.debug("\tReceived transfer response from {s}: token {d}", .{ self.username, msg.token });
                    // TODO: establish file connection now
                },
                .queueUpload => |msg| {
                    std.log.debug("\t{s} requests file '{s}'", .{ self.username, msg.filename });
                    // TODO: send transfer request
                },
                .uploadFailed => |msg| {
                    std.log.debug("\tReceived upload failure from {s}: {s}", .{ self.username, msg.filename });

                    // close oneshot channel, if someone is waiting
                    if (self.transfer_request_channel) |channel| {
                        channel.close(.graceful);
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
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Sends a PeerMessage to the peer.
    fn sendPeerMessage(self: *PeerConnection, rt: *zio.Runtime, msg: messages.PeerMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(self.allocator, writer_interface);
        try writer_interface.flush();
    }
};
