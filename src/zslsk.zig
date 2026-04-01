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

pub const DownloadChannel = struct {
    size: u64,
    channel: *zio.Channel(u8),
    buffer: []u8,
    handle: zio.JoinHandle(void),

    pub fn deinit(self: *DownloadChannel, rt: *zio.Runtime, allocator: std.mem.Allocator) void {
        self.handle.join(rt);
        allocator.free(self.buffer);
        allocator.destroy(self.channel);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected), // connection state
    socket: ?zio.net.Stream = null, // socket connection to centralized server
    p2p_server: ?zio.net.Server = null, // server listening for p2p connections
    peers: std.StringHashMap(*PeerConnection), // established peer connections
    peers_mutex: std.Thread.Mutex = .{},
    distributed_connections: std.StringHashMap(*DistributedConnection), // established distributed connections
    distributed_mutex: std.Thread.Mutex = .{},
    own_username: ?[]const u8 = null,
    connected_peer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    upload_queue_buf: []types.QueuedUpload,
    upload_queue: zio.Channel(types.QueuedUpload),
    active_uploads: std.atomic.Value(u32) = .init(0),
    upload_slots: u32 = 10,

    // map to route token to oneshot channels so indirect connections can be waited on
    indirect_channels: std.AutoHashMap(u32, *zio.Channel(types.ConnectionResult)),
    indirect_mutex: std.Thread.Mutex = .{},

    // consumer configurable fields
    shared_real_paths: std.StringHashMap([]const u8),
    shared_dirs: std.StringHashMap(messages.SharedDirectory),
    shared_priv_dirs: std.StringHashMap(messages.SharedDirectory),
    user_info: types.UserInfoConfig,

    // group for peer task execution
    peer_group: zio.Group = .init,

    // oneshot channels for request-response, keyed by username for concurrency
    get_peer_address_channels: std.StringHashMap(*zio.Channel(messages.GetPeerAddressResponse)),
    user_interests_channels: std.StringHashMap(*zio.Channel(messages.UserInterestsResponse)),
    waiters_mutex: std.Thread.Mutex = .{},

    // channels for streaming request-response
    search_result_channels: std.AutoHashMap(u32, SearchChannel),
    search_mutex: std.Thread.Mutex = .{},

    /// Exported Library Functions ///
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Client {
        const upload_buf = try allocator.alloc(types.QueuedUpload, 64);
        return .{
            .allocator = allocator,
            .io = io,
            .peers = .init(allocator),
            .upload_queue_buf = upload_buf,
            .upload_queue = .init(upload_buf),
            .indirect_channels = .init(allocator),
            .shared_real_paths = .init(allocator),
            .shared_dirs = .init(allocator),
            .shared_priv_dirs = .init(allocator),
            .user_info = .{
                .description = try allocator.dupe(u8, "hello from https://github.com/lumaaaaaa/zslsk"), // heap allocate bio
                .picture = null,
            },
            .distributed_connections = .init(allocator),
            .get_peer_address_channels = .init(allocator),
            .user_interests_channels = .init(allocator),
            .search_result_channels = .init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.own_username) |username| self.allocator.free(username);
        self.allocator.free(self.upload_queue_buf);
        self.get_peer_address_channels.deinit();

        var search_iter = self.search_result_channels.iterator();
        while (search_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.buffer);
            self.allocator.destroy(entry.value_ptr.channel);
        }
        self.search_result_channels.deinit();
        self.allocator.free(self.user_info.description);
        if (self.user_info.picture) |p| self.allocator.free(p);

        self.peers.deinit();
        self.distributed_connections.deinit();
    }

    pub fn disconnect(self: *Client, rt: *zio.Runtime) void {
        // disconnect (this should cascade and shut down loops)
        self.connection_state.store(.disconnected, .seq_cst);

        // shut down our connections
        if (self.socket) |s| s.close(rt);
        if (self.p2p_server) |s| s.close(rt);

        // close upload queue
        self.upload_queue.close(.graceful);

        // close searches
        self.search_mutex.lock();
        var search_iter = self.search_result_channels.iterator();
        while (search_iter.next()) |channel| {
            channel.value_ptr.*.channel.close(.graceful);
        }
        self.search_mutex.unlock();

        // close peer connections so their read loops exit
        self.peers_mutex.lock();
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            entry.value_ptr.*.connection_state.store(.disconnected, .seq_cst);
            if (entry.value_ptr.*.socket) |s| s.close(rt);
        }
        self.peers_mutex.unlock();

        // close distributed connections too
        self.distributed_mutex.lock();
        var dist_iter = self.distributed_connections.iterator();
        while (dist_iter.next()) |entry| {
            entry.value_ptr.*.connection_state.store(.disconnected, .seq_cst);
            if (entry.value_ptr.*.socket) |s| s.close(rt);
        }
        self.distributed_mutex.unlock();
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

        // tell the server we're an orphan
        const have_no_parent_msg = messages.HaveNoParentMessage{
            .no_parent = true,
        };
        try self.sendMessage(rt, .{ .haveNoParent = have_no_parent_msg });

        // we're connected!
        self.connection_state.store(.connected, .seq_cst);

        // dispatch concurrent tasks
        try self.peer_group.spawn(rt, p2pListenerTask, .{ self, rt, listen_port }); // p2p listener
        try self.peer_group.spawn(rt, uploadQueueTask, .{ self, rt }); // upload queue dispatcher

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

    /// Sets profile description in user info.
    pub fn setDescription(self: *Client, description: []const u8) !void {
        const dupe = try self.allocator.dupe(u8, description);
        self.allocator.free(self.user_info.description);
        self.user_info.description = dupe;
    }

    /// Sets profile picture in user info.
    pub fn setPicture(self: *Client, picture: ?[]const u8) !void {
        if (self.user_info.picture) |p| self.allocator.free(p);
        self.user_info.picture = if (picture) |p| try self.allocator.dupe(u8, p) else null;
    }

    /// Adds a "like" entry to our profile's interest list.
    pub fn addLikeInterest(self: *Client, rt: *zio.Runtime, like: []const u8) !void {
        try self.sendMessage(rt, .{ .addThingILike = .{ .like = like } });
    }

    /// Removes a "like" entry to our profile's interest list.
    pub fn removeLikeInterest(self: *Client, rt: *zio.Runtime, like: []const u8) !void {
        try self.sendMessage(rt, .{ .removeThingILike = .{ .like = like } });
    }

    /// Adds a "hate" entry to our profile's interest list.
    pub fn addHateInterest(self: *Client, rt: *zio.Runtime, hate: []const u8) !void {
        try self.sendMessage(rt, .{ .addThingIHate = .{ .hate = hate } });
    }

    /// Removes a "hate" entry to our profile's interest list.
    pub fn removeHateInterest(self: *Client, rt: *zio.Runtime, hate: []const u8) !void {
        try self.sendMessage(rt, .{ .removeThingIHate = .{ .hate = hate } });
    }

    /// Adds a directory to the share list. Expects path to be absolute.
    pub fn addShare(self: *Client, rt: *zio.Runtime, path: []const u8) !void {
        const dir = try std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        try self.scanDir(rt, dir, std.fs.path.basename(path), path, &self.shared_dirs);
    }

    /// Adds a directory to the private share list.
    pub fn addPrivateShare(self: *Client, rt: *zio.Runtime, path: []const u8) !void {
        const dir = try std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        try self.scanDir(rt, dir, std.fs.path.basename(path), path, &self.shared_priv_dirs);
    }

    /// Gets user info of the user with the specified username.
    pub fn getUserInfo(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.UserInfoMessage {
        // get the peer
        const conn = try self.getOrCreatePeer(rt, username);

        // get user info
        return try conn.getUserInfo(rt);
    }

    /// Gets user interests of the user with the specified username.
    pub fn getUserInterests(self: *Client, rt: *zio.Runtime, username: []const u8) !messages.UserInterestsResponse {
        // create oneshot channel for request-response
        var one: [1]messages.UserInterestsResponse = undefined;
        var channel = zio.Channel(messages.UserInterestsResponse).init(&one);
        defer channel.close(.graceful);

        // register
        self.waiters_mutex.lock();
        try self.user_interests_channels.put(username, &channel);
        self.waiters_mutex.unlock();

        // unregister on exit
        defer {
            self.waiters_mutex.lock();
            _ = self.user_interests_channels.remove(username);
            self.waiters_mutex.unlock();
        }

        // request peer address
        try self.sendMessage(rt, .{ .userInterests = messages.UserInterestsMessage{ .username = username } });

        // block until we receive a response
        return channel.receive(rt);
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
        // generate a random token to track the search
        var token: u32 = undefined;
        self.io.random(std.mem.asBytes(&token));

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
    pub fn downloadFile(self: *Client, rt: *zio.Runtime, username: []const u8, filepath: []const u8) !DownloadChannel {
        // get the peer
        const peer = try self.getOrCreatePeer(rt, username);

        // request download, return file content
        return try peer.queueDownload(rt, filepath);
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

    /// Requests the IP address and listening port for a specified username from the server.
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
    // Recursive function to scan a directory and append entries to a destination map.
    fn scanDir(self: *Client, rt: *zio.Runtime, dir: std.Io.Dir, path: []const u8, abs_path: []const u8, dest: *std.StringHashMap(messages.SharedDirectory)) !void {
        // storage for SharedFile objects in directory
        var files: std.ArrayList(messages.SharedFile) = .empty;
        errdefer files.deinit(self.allocator);

        // iterate target directory
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            switch (entry.kind) {
                .file => {
                    // append to files
                    const ext = std.fs.path.extension(entry.name);
                    const stat = try dir.statFile(self.io, entry.name, .{});
                    try files.append(self.allocator, .{
                        .code = 1,
                        .name = try self.allocator.dupe(u8, entry.name),
                        .size = stat.size,
                        .extension = try self.allocator.dupe(u8, ext),
                        .attributes = &.{},
                    });
                },
                .directory => {
                    // open subdirectory and recurse
                    const sub_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                    defer self.allocator.free(sub_path);

                    const sub_abs_path = try std.fs.path.join(self.allocator, &.{ abs_path, entry.name });
                    defer self.allocator.free(sub_abs_path);

                    const sub_dir = try dir.openDir(self.io, entry.name, .{ .iterate = true });
                    defer sub_dir.close(self.io);

                    try self.scanDir(rt, sub_dir, sub_path, sub_abs_path, dest);
                },
                else => {}, // ignore
            }
        }

        if (files.items.len > 0) {
            const win_path = try toWindowsPath(self.allocator, path);
            errdefer self.allocator.free(win_path);

            const real_path = try self.allocator.dupe(u8, abs_path);
            errdefer self.allocator.free(real_path);

            // add to destination map
            try dest.put(win_path, .{
                .name = win_path,
                .files = try files.toOwnedSlice(self.allocator),
            });
            try self.shared_real_paths.put(win_path, real_path);
        }
    }

    // Converts Unix paths to Windows paths. Soulseek uses Windows paths in the protocol.
    fn toWindowsPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return try std.mem.replaceOwned(u8, allocator, path, "/", "\\");
    }

    // Converts the internal share map representation to the proper protocol structure.
    fn formatShares(self: *Client, map: *const std.StringHashMap(messages.SharedDirectory)) ![]messages.SharedDirectory {
        const list = try self.allocator.alloc(messages.SharedDirectory, map.count());
        var i: usize = 0;

        // drop keys
        var it = map.valueIterator();
        while (it.next()) |entry| {
            list[i] = entry.*;
            i += 1;
        }

        return list;
    }

    // Processes the upload queue in accordance with the number of available slots.
    fn uploadQueueTask(self: *Client, rt: *zio.Runtime) void {
        while (self.connection_state.load(.seq_cst) == .connected) {
            var upload = self.upload_queue.receive(rt) catch return;

            // wait for uploads to finish if slots are full
            while (self.active_uploads.load(.seq_cst) >= self.upload_slots) {
                rt.sleep(.fromMilliseconds(100)) catch return;
            }

            // dispatch task to handle upload
            self.peer_group.spawn(rt, uploadTask, .{ self, rt, upload }) catch {
                upload.deinit(self.allocator);
                continue;
            };
        }
    }

    // Performs an upload to a peer.
    fn uploadTask(self: *Client, rt: *zio.Runtime, u: types.QueuedUpload) void {
        var upload = u; // mutable
        // cleanup on exit
        defer {
            _ = self.active_uploads.fetchSub(1, .seq_cst); // decrement active upload counter
            upload.deinit(self.allocator);
        }
        _ = self.active_uploads.fetchAdd(1, .seq_cst); // increment active upload counter

        // get peer to upload to
        const peer = self.getOrCreatePeer(rt, upload.username) catch |err| {
            std.log.err("Upload to peer {s} failed getting peer: {}", .{ upload.username, err });
            return;
        };

        // generate token to track transfer
        var token: u32 = undefined;
        self.io.random(std.mem.asBytes(&token));

        // create oneshot channel for request-response
        var xfer_one: [1]messages.TransferResponseMessage = undefined;
        var xfer_channel = zio.Channel(messages.TransferResponseMessage).init(&xfer_one);
        defer xfer_channel.close(.graceful);

        // register
        peer.channels_mutex.lock();
        peer.transfer_response_channels.put(token, &xfer_channel) catch return;
        peer.channels_mutex.unlock();

        // unregister on exit
        defer {
            peer.channels_mutex.lock();
            _ = peer.transfer_response_channels.remove(token);
            peer.channels_mutex.unlock();
        }

        // send TransferRequest to peer
        peer.sendPeerMessage(rt, .{
            .transferRequest = .{
                .direction = .uploadToPeer,
                .token = token,
                .filename = upload.filename,
                .size = upload.size,
            },
        }) catch |err| {
            std.log.err("Upload to peer {s} failed sending TransferRequest: {}", .{ upload.username, err });
            return;
        };

        // block until we receive a transfer response
        var transfer_response_msg = xfer_channel.receive(rt) catch |err| {
            std.log.err("Upload to peer {s} failed waiting for TransferResponse: {}", .{ upload.username, err });
            return;
        };
        defer transfer_response_msg.deinit(self.allocator);

        // check if allowed
        if (!transfer_response_msg.allowed) {
            std.log.err("Upload to peer {s} failed, peer denied upload", .{upload.username});
            return;
        }

        // establish F connection
        const file_conn = self.establishFileConnection(rt, peer, token) catch |err| {
            std.log.err("Upload to peer {s} failed, could not establish file connection: {}", .{ upload.username, err });
            return;
        };
        defer {
            file_conn.deinit(rt);
            self.allocator.destroy(file_conn);
        }

        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = file_conn.socket.?.reader(rt, &read_buf);

        // send FileTransferInit
        file_conn.sendFileMessage(rt, .{ .fileTransferInit = .{ .token = token } }) catch |err| {
            std.log.err("Upload to peer {s} failed, could not send FileTransferInit: {}", .{ upload.username, err });
            return;
        };

        // read FileOffset
        const file_offset_msg = file_conn.readOffsetMessage(&reader) catch |err| {
            std.log.err("Upload to peer {s} failed, could not read FileOffset: {}", .{ upload.username, err });
            return;
        };

        // open file to upload
        const file = std.Io.Dir.openFileAbsolute(self.io, upload.real_path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Upload to peer {s} failed, could not open file at path {s}: {}", .{ upload.username, upload.real_path, err });
            return;
        };
        defer file.close(self.io);

        // reader for file
        var file_read_buf: [4096]u8 = undefined;
        var file_reader = file.reader(self.io, &file_read_buf);
        file_reader.seekTo(file_offset_msg.offset) catch |err| {
            std.log.err("Upload to peer {s} failed, could not seek file at path {s} to position {d}: {}", .{ upload.username, upload.real_path, file_offset_msg.offset, err });
            return;
        };

        // writer for socket
        var write_buf: [4096]u8 = undefined;
        var writer = file_conn.socket.?.writer(rt, &write_buf);

        // stream from reader to writer
        _ = file_reader.interface.streamRemaining(&writer.interface) catch |err| {
            std.log.err("Upload to peer {s} failed, could not stream file contents to peer: {}", .{ upload.username, err });
            return;
        };
        writer.interface.flush() catch |err| {
            std.log.err("Upload to peer {s} failed, could not flush writer: {}", .{ upload.username, err });
            return;
        };
    }

    // Establishes a file connection (type F) with a specified username.
    fn establishFileConnection(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, token: u32) !*FileConnection {
        // oneshot channel to receive the FileConnection
        var one: [1]types.ConnectionResult = undefined;
        var channel = zio.Channel(types.ConnectionResult).init(&one);
        defer channel.close(.graceful);

        // register
        self.indirect_mutex.lock();
        try self.indirect_channels.put(token, &channel);
        self.indirect_mutex.unlock();

        // unregister on exit
        defer {
            self.indirect_mutex.lock();
            _ = self.indirect_channels.remove(token);
            self.indirect_mutex.unlock();
        }

        // request indirect connection
        try self.sendMessage(rt, .{
            .connectToPeer = .{
                .token = token,
                .username = peer.username,
                .type = @tagName(types.ConnectionType.F),
            },
        });

        // direct connection task logic
        const DirectConnectionTask = struct {
            fn run(client: *Client, runtime: *zio.Runtime, username: []const u8, ch: *zio.Channel(types.ConnectionResult)) void {
                // get address of peer
                var addr_resp = client.getPeerAddress(runtime, username) catch return;
                defer addr_resp.deinit(client.allocator);

                // attempt connection
                const address = zio.net.IpAddress.initIp4(addr_resp.ip, @intCast(addr_resp.port));
                const stream = zio.net.tcpConnectToAddress(runtime, address, .{
                    .timeout = .{ .duration = .fromSeconds(20) },
                }) catch return;

                // send in channel
                ch.trySend(.{
                    .stream = stream,
                    .direct = true,
                }) catch {
                    stream.close(runtime);
                };
            }
        };

        // race direct vs. indirect
        try self.peer_group.spawn(rt, DirectConnectionTask.run, .{ self, rt, peer.username, &channel });

        // grab winner
        const result = try channel.receive(rt);

        // create file connection
        const file_conn = try FileConnection.init(self.allocator, peer.username, token);
        file_conn.socket = result.stream;

        // handshake if direct, PierceFireWall consumed in P2P listener
        if (result.direct) {
            // we need to send PeerInit
            file_conn.sendPeerInitMessage(rt, .{
                .peerInit = .{
                    .username = self.own_username.?,
                    .type = @tagName(types.ConnectionType.F),
                    .token = 0,
                },
            }) catch {
                file_conn.deinit(rt);
                self.allocator.destroy(file_conn);
                return error.HandshakeFailed;
            };
        }

        return file_conn;
    }

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
            self.peer_group.spawn(rt, handleIncomingPeer, .{ self, rt, stream }) catch |err| {
                std.log.err("Could not spawn thread to handle incoming P2P connection: {}", .{err});
            };
        }
    }

    // Handles in incoming P2P connection.
    fn handleIncomingPeer(self: *Client, rt: *zio.Runtime, stream: zio.net.Stream) void {
        // initialize socket reader and writer
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(rt, &read_buf);

        // parse message header
        const payload_len = reader.interface.takeInt(u32, .little) catch |err| { // TODO: will probably need to store this and use it for validation
            std.log.err("Error reading payload length of initial message from incoming connection: {}", .{err});
            stream.close(rt);
            return;
        };
        if (payload_len < 1) {
            std.log.err("Invalid handshake message received on P2P listener. Payload length has no space for message code.", .{});
            stream.close(rt);
            return;
        }
        const message_code = reader.interface.takeInt(u8, .little) catch |err| {
            std.log.err("Error reading message code of initial message from incoming connection: {}", .{err});
            stream.close(rt);
            return;
        };

        if (message_code == 0) {
            // PierceFireWall received, this is an outgoing indirect connection we requested

            // read incoming PierceFireWall to get token
            var pierce_firewall_msg = messages.PierceFireWall.parse(&reader.interface) catch |err| {
                std.log.err("Error reading PierceFireWall message from incoming connection: {}", .{err});
                stream.close(rt);
                return;
            };
            defer pierce_firewall_msg.deinit(self.allocator);

            // check if we're waiting for this connection
            if (self.indirect_channels.get(pierce_firewall_msg.token)) |channel| {
                channel.send(rt, .{
                    .stream = stream,
                    .direct = false,
                }) catch stream.close(rt);
            } else {
                std.log.warn("Received unexpected PierceFirewall with token {d}", .{pierce_firewall_msg.token});
                stream.close(rt);
            }

            return;
        } else if (message_code == 1) {
            // PeerInit received, this is an incoming direct connection

            // read incoming PeerInit to get username and message type
            var peer_init_msg = messages.PeerInit.parse(self.allocator, &reader.interface) catch |err| {
                std.log.err("Error reading PeerInit message from incoming connection: {}", .{err});
                stream.close(rt);
                return;
            };
            defer peer_init_msg.deinit(self.allocator);

            // TODO: handle all different connection types
            const connection_type = std.meta.stringToEnum(types.ConnectionType, peer_init_msg.type) orelse {
                std.log.err("Peer requested an unknown connection type", .{});
                return;
            };
            switch (connection_type) {
                .P => {
                    std.log.debug("Incoming direct peer connection from user '{s}'", .{peer_init_msg.username});

                    // get peer
                    self.peers_mutex.lock();
                    const peer_gop = self.peers.getOrPut(peer_init_msg.username) catch |err| {
                        std.log.err("Error getting peer: {}", .{err});
                        stream.close(rt);
                        return;
                    };
                    if (peer_gop.found_existing) {
                        // peer with username exists
                        const peer = peer_gop.value_ptr.*;
                        if (peer.connection_state.load(.seq_cst) == .connected) {
                            // the indirect connection won the race
                            self.peers_mutex.unlock();
                            stream.close(rt);
                            return;
                        } else {
                            // we've won the race, assume ownership of peer
                            peer.connection_state.store(.connected, .seq_cst);
                            const old_socket = peer.socket;
                            peer.socket = stream;
                            self.peers_mutex.unlock();

                            // close socket to trigger teardown on other thread
                            if (old_socket) |sock| sock.close(rt);

                            // run peer (reuse buffered reader)
                            peer.run(rt, .incoming, &reader);

                            // cleanup (like runPeer)
                            self.peers_mutex.lock();
                            _ = self.peers.remove(peer.username);
                            std.log.debug("Peer '{s}' disconnected. There are now {d} active P2P connections.", .{ peer.username, self.connected_peer_count.load(.seq_cst) });
                            self.peers_mutex.unlock();
                            peer.deinit(rt);
                            self.allocator.destroy(peer);
                        }
                    } else {
                        // new peer
                        const peer = PeerConnection.init(self.allocator, self, peer_init_msg.username, self.own_username.?, peer_init_msg.token) catch |err| {
                            std.log.err("Error initializing peer: {}", .{err});
                            _ = self.peers.remove(peer_init_msg.username);
                            self.peers_mutex.unlock();
                            return;
                        };

                        // already connected, directly assign socket
                        peer.socket = stream;

                        // update hashmap ptrs before releasing lock
                        peer_gop.key_ptr.* = peer.username; // update key to peer owned memory
                        peer_gop.value_ptr.* = peer;
                        self.peers_mutex.unlock();

                        // run peer (reuse buffered reader)
                        peer.run(rt, .incoming, &reader);

                        // cleanup (like runPeer)
                        self.peers_mutex.lock();
                        _ = self.peers.remove(peer.username);
                        std.log.debug("Peer '{s}' disconnected. There are now {d} active P2P connections.", .{ peer.username, self.connected_peer_count.load(.seq_cst) });
                        self.peers_mutex.unlock();
                        peer.deinit(rt);
                        self.allocator.destroy(peer);
                    }
                },
                .F => {
                    std.log.debug("Incoming direct file connection from user '{s}'", .{peer_init_msg.username});
                    std.log.warn("Unimplemented!", .{});
                    stream.close(rt);
                    return;
                },
                .D => {
                    std.log.debug("Incoming direct distributed connection from user '{s}'", .{peer_init_msg.username});
                    std.log.warn("Unimplemented!", .{});
                    stream.close(rt);
                    return;
                },
            }
        } else {
            std.log.err("A user attempted to start an incoming connection with an unexpected message.", .{});
            stream.close(rt);
            return;
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
                .userInterests => |resp| {
                    std.log.debug("\tReceived {s}'s interests", .{resp.username});
                    should_deinit = false;

                    // send response in corresponding user interests oneshot channel
                    if (self.user_interests_channels.get(resp.username)) |channel| {
                        channel.send(rt, resp) catch |err| {
                            std.log.err("Could not send UserInterestsResponse in oneshot channel: {}", .{err});
                        };
                    }
                },
                .roomList => |resp| std.log.debug("\tRoom counts: {d} total, {d} owned private, {d} unowned private, {d} operated private", .{ resp.rooms.len, resp.owned_private_rooms.len, resp.unowned_private_rooms.len, resp.operated_private_rooms.len }),
                .privilegedUsers => |resp| std.log.debug("\tPrivileged user count: {d}", .{resp.users.len}), // just print for now
                .parentMinSpeed => |resp| std.log.debug("\tMinimum upload speed to become parent: {d}", .{resp.speed}), // just print for now
                .parentSpeedRatio => |resp| std.log.debug("\tParent speed ratio: {d}", .{resp.ratio}), // just print for now
                .possibleParents => |resp| {
                    std.log.debug("\tReceived a list of {d} possible parents", .{resp.parents.len});
                    should_deinit = false;

                    self.peer_group.spawn(rt, handlePossibleParents, .{ self, rt, resp }) catch |err| {
                        std.log.err("Could not spawn thread to handle PossibleParent message: {}", .{err});
                    };
                },
                .wishlistSearch => |resp| std.log.debug("\tWishlist search interval: {d} seconds", .{resp.interval}), // just print for now
                .excludedSearchPhrases => |resp| std.log.debug("\tExcluded search phrase count: {d}", .{resp.phrases.len}), // TODO: store these phrases, search requests should exclude paths containing these strings
            }
        }
    }

    // Message handler for PossibleParents, establishes a distributed connection to a parent.
    fn handlePossibleParents(self: *Client, rt: *zio.Runtime, resp: messages.PossibleParentsResponse) void {
        var msg = resp;
        defer msg.deinit(self.allocator);

        // attempt distributed connections until one succeeds
        for (msg.parents) |parent| {
            // check port validity
            const port = std.math.cast(u16, parent.port) orelse continue;
            // get distributed connection
            self.distributed_mutex.lock();
            const distributed_gop = self.distributed_connections.getOrPut(parent.username) catch |err| {
                std.log.err("Error getting distributed connection: {}", .{err});
                return;
            };
            if (distributed_gop.found_existing) {
                // distributed connection with username exists
                self.distributed_mutex.unlock();
                return;
            }

            // new distributed connection
            const distributed_conn = DistributedConnection.init(self.allocator, parent.username, self.own_username.?, 0) catch |err| {
                std.log.err("Error initializing distributed connection: {}", .{err});
                _ = self.distributed_connections.remove(parent.username);
                self.distributed_mutex.unlock();
                return;
            };

            // update hashmap ptrs before releasing lock
            distributed_gop.key_ptr.* = distributed_conn.username; // update key to distributed connection owned memory
            distributed_gop.value_ptr.* = distributed_conn;
            self.distributed_mutex.unlock();

            // attempt connection
            distributed_conn.connect(rt, parent.ip, port) catch |err| {
                // cancellations and timeouts are normal behavior, no need to print anything
                // honestly, this is debug log level for now since connection errors are common, not worth attention
                if (err != error.Canceled and err != error.Timeout) {
                    std.log.debug("Error connecting to distributed peer: {}", .{err});
                }

                self.distributed_mutex.lock();
                _ = self.distributed_connections.remove(parent.username);
                self.distributed_mutex.unlock();
                distributed_conn.deinit(rt);
                self.allocator.destroy(distributed_conn);
                continue;
            };

            // spawn distributed connection and run
            self.spawnDistributedPeer(rt, distributed_conn, true) catch |err| {
                std.log.err("Error spawning & running distributed peer: {}", .{err});
                continue;
            };

            return;
        }
    }

    // Message handler for ConnectToPeer, establishes an indirect peer connection.
    fn handleConnectToPeer(self: *Client, rt: *zio.Runtime, resp: messages.ConnectToPeerResponse) void {
        var msg = resp;
        defer msg.deinit(self.allocator);

        // TODO: handle all different connection types
        const connection_type = std.meta.stringToEnum(types.ConnectionType, msg.type) orelse {
            std.log.err("Peer requested an unknown connection type", .{});
            return;
        };
        switch (connection_type) {
            // p2p
            types.ConnectionType.P => {
                // get peer
                self.peers_mutex.lock();
                const peer_gop = self.peers.getOrPut(msg.username) catch |err| {
                    std.log.err("Error getting peer: {}", .{err});
                    return;
                };
                if (peer_gop.found_existing) {
                    // peer with username exists, no need to continue
                    self.peers_mutex.unlock();
                    return;
                }

                // new peer
                const peer = PeerConnection.init(self.allocator, self, msg.username, self.own_username.?, msg.token) catch |err| {
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
                    // honestly, this is debug log level for now since connection errors are common, not worth attention
                    if (err != error.Canceled and err != error.Timeout) {
                        std.log.debug("Error connecting to peer: {}", .{err});
                    }

                    self.peers_mutex.lock();
                    // check if race lost to incoming direct connection
                    if (peer.connection_state.load(.seq_cst) == .connected) {
                        // race lost, peer is owned
                        self.peers_mutex.unlock();
                        return;
                    }
                    _ = self.peers.remove(msg.username);
                    self.peers_mutex.unlock();
                    peer.deinit(rt); // peer is not yet running, deinit
                    self.allocator.destroy(peer);
                    return;
                };

                // spawn peer and run
                self.spawnPeer(rt, peer, .outgoing_indirect) catch |err| {
                    std.log.err("Error spawning & running peer: {}", .{err});
                };
            },
            // file transfer
            types.ConnectionType.F => {
                // get peer
                self.peers_mutex.lock();
                const peer = self.peers.get(msg.username) orelse {
                    std.log.err("Error establishing file transfer connection with {s}, peer connection does not exist", .{msg.username});
                    return;
                };
                self.peers_mutex.unlock();

                // initialize new file connection
                const file_conn = FileConnection.init(self.allocator, msg.username, msg.token) catch |err| {
                    std.log.err("Error initializing file connection for {s}: {}", .{ msg.username, err });
                    return;
                };

                // establish file connection
                file_conn.connect(rt, msg.ip, @intCast(msg.port)) catch |err| {
                    // cancellations and timeouts are normal behavior, no need to print anything
                    if (err != error.Canceled and err != error.Timeout) {
                        std.log.err("Error establishing file connection with {s}: {}", .{ msg.username, err });
                    }
                    file_conn.deinit(rt);
                    self.allocator.destroy(file_conn);
                    return;
                };

                // shoot file connection to peer (if waiting)
                if (peer.file_connection_channel) |channel| {
                    channel.send(rt, file_conn) catch |err| {
                        std.log.err("Error sending file connection to peer {s}: {}", .{ msg.username, err });
                        file_conn.deinit(rt);
                        self.allocator.destroy(file_conn);
                        return;
                    };
                } else {
                    std.log.err("Error creating file connection for {s}: peer is not expecting file connection", .{msg.username});
                    file_conn.deinit(rt);
                    self.allocator.destroy(file_conn);
                    return;
                }
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
        const peer = PeerConnection.init(self.allocator, self, username, self.own_username.?, 0) catch |err| {
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
        try self.spawnPeer(rt, peer, .outgoing_direct);

        return peer;
    }

    // Spawns peer and begins running.
    fn spawnPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, handshake_type: types.HandshakeType) !void {
        try self.peer_group.spawn(rt, runPeer, .{ self, rt, peer, handshake_type });
    }

    // Runs the peer.
    fn runPeer(self: *Client, rt: *zio.Runtime, peer: *PeerConnection, handshake_type: types.HandshakeType) void {
        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = peer.socket.?.reader(rt, &read_buf);

        peer.run(rt, handshake_type, &reader);

        // cleanup
        self.peers_mutex.lock();
        _ = self.peers.remove(peer.username);
        std.log.debug("Peer '{s}' disconnected. There are now {d} active P2P connections.", .{ peer.username, self.connected_peer_count.load(.seq_cst) });
        self.peers_mutex.unlock();
        peer.deinit(rt);
        self.allocator.destroy(peer);
    }

    // Spawns distributed peer and begins running.
    fn spawnDistributedPeer(self: *Client, rt: *zio.Runtime, peer: *DistributedConnection, we_initiated: bool) !void {
        try self.peer_group.spawn(rt, runDistributedPeer, .{ self, rt, peer, we_initiated });
    }

    // Runs the distributed peer.
    fn runDistributedPeer(self: *Client, rt: *zio.Runtime, peer: *DistributedConnection, we_initiated: bool) void {
        peer.run(rt, we_initiated);

        // cleanup
        self.distributed_mutex.lock();
        _ = self.distributed_connections.remove(peer.username);
        std.log.debug("Distributed peer '{s}' disconnected.", .{peer.username});
        self.distributed_mutex.unlock();
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
        if (payload_len < 4) return error.InvalidMessage;
        const message_code = try reader.interface.takeInt(u32, .little);

        // handoff to relevant parser
        return switch (message_code) {
            1 => .{ .login = try messages.LoginResponse.parse(&reader.interface, self.allocator, payload_len) },
            3 => .{ .getPeerAddress = try messages.GetPeerAddressResponse.parse(&reader.interface, self.allocator) },
            18 => .{ .connectToPeer = try messages.ConnectToPeerResponse.parse(&reader.interface, self.allocator) },
            22 => .{ .messageUser = try messages.MessageUserResponse.parse(&reader.interface, self.allocator) },
            57 => .{ .userInterests = try messages.UserInterestsResponse.parse(&reader.interface, self.allocator) },
            64 => .{ .roomList = try messages.RoomListResponse.parse(&reader.interface, self.allocator) },
            69 => .{ .privilegedUsers = try messages.PrivilegedUsersResponse.parse(&reader.interface, self.allocator) },
            83 => .{ .parentMinSpeed = try messages.ParentMinSpeedResponse.parse(&reader.interface) },
            84 => .{ .parentSpeedRatio = try messages.ParentSpeedRatioResponse.parse(&reader.interface) },
            102 => .{ .possibleParents = try messages.PossibleParentsResponse.parse(&reader.interface, self.allocator) },
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

pub const DistributedConnection = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    own_username: []const u8,
    token: u32,
    socket: ?zio.net.Stream = null,

    // connection state
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected),

    pub fn init(allocator: std.mem.Allocator, username: []const u8, own_username: []const u8, token: u32) !*DistributedConnection {
        const dc = try allocator.create(DistributedConnection);
        dc.* = .{
            .allocator = allocator,
            .username = try allocator.dupe(u8, username),
            .own_username = try allocator.dupe(u8, own_username),
            .token = token,
        };
        return dc;
    }

    pub fn deinit(self: *DistributedConnection, rt: *zio.Runtime) void {
        self.allocator.free(self.username);
        self.allocator.free(self.own_username);
        if (self.socket) |s| s.close(rt);
    }

    pub fn connect(self: *DistributedConnection, rt: *zio.Runtime, ip: [4]u8, port: u16) !void {
        std.log.debug("Establishing distributed connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
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
        std.log.debug("Connection established.", .{});
    }

    // Self-contained distributed connection logic.
    pub fn run(self: *DistributedConnection, rt: *zio.Runtime, we_initiated: bool) void {
        // reader for socket
        var read_buf: [4096]u8 = undefined;
        var reader = self.socket.?.reader(rt, &read_buf);

        // send correct handshake
        if (we_initiated) {
            const msg = messages.PeerInit{
                .username = self.own_username,
                .type = @tagName(types.ConnectionType.D),
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

    // Distributed connection message parser.
    fn readResponse(self: *DistributedConnection, reader: *zio.net.Stream.Reader) !messages.DistributedMessage {
        // TODO: handle error when socket is closed

        // parse message header
        const payload_len = try reader.interface.takeInt(u32, .little);
        if (payload_len < 1) return error.InvalidMessage;
        const message_code = try reader.interface.takeInt(u8, .little);

        // handoff to relevant parser
        return switch (message_code) {
            3 => .{ .search = try messages.SearchMessage.parse(self.allocator, &reader.interface) },
            4 => .{ .branchLevel = try messages.BranchLevelMessage.parse(&reader.interface) },
            5 => .{ .branchRoot = try messages.BranchRootMessage.parse(self.allocator, &reader.interface) },
            else => {
                std.log.warn("Distributed connection {s} readResponse dropped an unknown message. code: {d}, length: {d}", .{ self.username, message_code, payload_len });

                // discard
                const remaining: usize = payload_len - 1;
                try reader.interface.discardAll(remaining);

                std.log.debug("Discarded {d} bytes from TCP stream", .{remaining});
                return error.UnknownMessage;
            },
        };
    }

    // Distributed connection read loop.
    fn readLoop(self: *DistributedConnection, rt: *zio.Runtime, reader: *zio.net.Stream.Reader) void {
        _ = rt;
        while (self.connection_state.load(.seq_cst) == .connected) {
            var message = self.readResponse(reader) catch |err| {
                if (err == error.EndOfStream or err == error.ReadFailed) {
                    self.connection_state.store(.disconnected, .seq_cst);
                    return;
                }
                std.log.err("Error encountered in distributed peer readResponse: {}", .{err});
                continue;
            };

            // deinit message if it isn't returned
            const should_deinit = true;
            defer if (should_deinit) message.deinit(self.allocator);

            // handle async message types
            //std.log.debug("== Received DistributedMessage: {s} (code: {d}) ==", .{ @tagName(message), message.code() });
            switch (message) {
                .search => {
                    //std.log.debug("\tSearch: user {s} is looking for '{s}'", .{ msg.username, msg.query });
                },
                .branchLevel => |msg| {
                    std.log.debug("\tDistributed peer {s} has branch level {d}", .{ self.username, msg.level });
                },
                .branchRoot => |msg| {
                    std.log.debug("\tDistributed peer {s} has branch root {s}", .{ self.username, msg.root });
                },
            }
        }
    }

    // Sends one of the PeerInit messages: PierceFireWall or PeerInit.
    fn sendPeerInitMessage(self: *DistributedConnection, rt: *zio.Runtime, msg: messages.PeerInitMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Sends a DistributedMessage to the peer.
    fn sendDistributedMessage(self: *DistributedConnection, rt: *zio.Runtime, msg: messages.DistributedMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }
};

pub const FileConnection = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    token: u32,
    socket: ?zio.net.Stream = null,

    pub fn init(allocator: std.mem.Allocator, username: []const u8, token: u32) !*FileConnection {
        const fc = try allocator.create(FileConnection);
        fc.* = .{
            .allocator = allocator,
            .username = try allocator.dupe(u8, username),
            .token = token,
        };
        return fc;
    }

    pub fn deinit(self: *FileConnection, rt: *zio.Runtime) void {
        self.allocator.free(self.username);
        if (self.socket) |s| s.close(rt);
    }

    pub fn connect(self: *FileConnection, rt: *zio.Runtime, ip: [4]u8, port: u16) !void {
        std.log.debug("Establishing file connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
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

    // Reads a FileTransferInitMessage.
    fn readFileTransferInitMessage(self: *FileConnection, reader: *zio.net.Stream.Reader) !messages.FileTransferInitMessage {
        _ = self;
        return try messages.FileTransferInitMessage.parse(&reader.interface);
    }

    // Reads a FileOffsetMessage.
    fn readOffsetMessage(self: *FileConnection, reader: *zio.net.Stream.Reader) !messages.FileOffsetMessage {
        _ = self;
        return try messages.FileOffsetMessage.parse(&reader.interface);
    }

    // Sends one of the PeerInit messages: PierceFireWall or PeerInit.
    fn sendPeerInitMessage(self: *FileConnection, rt: *zio.Runtime, msg: messages.PeerInitMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }

    // Sends a FileMessage to the peer.
    fn sendFileMessage(self: *FileConnection, rt: *zio.Runtime, msg: messages.FileMessage) !void {
        // TODO: handle error when socket is closed

        // create buffered writer
        var write_buf: [4096]u8 = undefined;
        var writer = self.socket.?.writer(rt, &write_buf);
        const writer_interface = &writer.interface;
        try msg.write(writer_interface);
        try writer_interface.flush();
    }
};

pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    username: []const u8,
    own_username: []const u8,
    token: u32,
    socket: ?zio.net.Stream,

    // oneshot channels for request-response
    user_info_channel: ?*zio.Channel(messages.UserInfoMessage) = null,
    shared_file_list_channel: ?*zio.Channel(messages.SharedFileListMessage) = null,
    transfer_request_channel: ?*zio.Channel(messages.TransferRequestMessage) = null,
    transfer_response_channels: std.AutoHashMap(u32, *zio.Channel(messages.TransferResponseMessage)),

    // oneshot channel for file connections socket
    file_connection_channel: ?*zio.Channel(*FileConnection) = null,

    // mutex for channel access
    channels_mutex: std.Thread.Mutex = .{},

    // connection state
    connection_state: std.atomic.Value(ConnectionState) = std.atomic.Value(ConnectionState).init(.disconnected),

    pub fn init(allocator: std.mem.Allocator, client: *Client, username: []const u8, own_username: []const u8, token: u32) !*PeerConnection {
        const pc = try allocator.create(PeerConnection);
        pc.* = .{
            .allocator = allocator,
            .client = client,
            .socket = null,
            .username = try allocator.dupe(u8, username),
            .own_username = try allocator.dupe(u8, own_username),
            .token = token,
            .transfer_response_channels = .init(allocator),
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
        if (self.transfer_request_channel) |c| c.close(.graceful);
        self.transfer_response_channels.deinit();
    }

    pub fn connect(self: *PeerConnection, rt: *zio.Runtime, ip: [4]u8, port: u16) !void {
        std.log.debug("Establishing peer connection with {s} @ {d}.{d}.{d}.{d}:{d}...", .{
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
    pub fn run(self: *PeerConnection, rt: *zio.Runtime, handshake_type: types.HandshakeType, reader: *zio.net.Stream.Reader) void {
        // send correct handshake
        switch (handshake_type) {
            .outgoing_direct => {
                const msg = messages.PeerInit{
                    .username = self.own_username,
                    .type = @tagName(types.ConnectionType.P),
                    .token = 0,
                };

                self.sendPeerInitMessage(rt, .{ .peerInit = msg }) catch |err| {
                    std.log.err("Failed to send PeerInit to {s}: {}", .{ self.username, err });
                    return;
                };
            },
            .outgoing_indirect => {
                const msg = messages.PierceFireWall{
                    .token = self.token,
                };

                self.sendPeerInitMessage(rt, .{ .pierceFireWall = msg }) catch |err| {
                    std.log.err("Failed to send PierceFirewall to {s}: {}", .{ self.username, err });
                    return;
                };
            },
            .incoming => {
                // PeerInit was read by our P2P handler, no need to do anything here
            },
        }

        // handshake done, good to go
        std.log.debug("Handshake complete with {s}, beginning read loop", .{self.username});
        self.connection_state.store(.connected, .seq_cst);

        // update metrics in our client
        _ = self.client.connected_peer_count.fetchAdd(1, .seq_cst);
        defer _ = self.client.connected_peer_count.fetchSub(1, .seq_cst);

        // begin read loop
        self.readLoop(rt, reader);
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

    pub fn queueDownload(self: *PeerConnection, rt: *zio.Runtime, filepath: []const u8) !DownloadChannel {
        // wait for handshake
        while (self.connection_state.load(.seq_cst) != .connected) {
            try rt.sleep(.fromMilliseconds(1));
        }

        // create oneshot channel for request-response
        var xfer_one: [1]messages.TransferRequestMessage = undefined;
        var xfer_channel = zio.Channel(messages.TransferRequestMessage).init(&xfer_one);
        defer xfer_channel.close(.graceful);

        // register
        self.channels_mutex.lock();
        self.transfer_request_channel = &xfer_channel;
        self.channels_mutex.unlock();

        // unregister on exit
        defer {
            self.channels_mutex.lock();
            self.transfer_request_channel = null;
            self.channels_mutex.unlock();
        }

        // ask peer to queue download
        try self.sendPeerMessage(rt, .{ .queueUpload = .{ .filename = filepath } });

        // block until we receive a transfer request
        var transfer_request_msg = try xfer_channel.receive(rt);
        defer transfer_request_msg.deinit(self.allocator);

        // create oneshot channel for file connection socket
        var file_one: [1]*FileConnection = undefined;
        var file_channel = zio.Channel(*FileConnection).init(&file_one);
        defer file_channel.close(.graceful);

        // register
        self.channels_mutex.lock();
        self.file_connection_channel = &file_channel;
        self.channels_mutex.unlock();

        // unregister on exit
        defer {
            self.channels_mutex.lock();
            self.file_connection_channel = null;
            self.channels_mutex.unlock();
        }

        // respond to transfer response
        const transfer_response_msg = messages.TransferResponseMessage{
            .token = transfer_request_msg.token,
            .allowed = true,
            .size = 0,
            .reason = null,
            .direction = .uploadToPeer,
        };
        try self.sendPeerMessage(rt, .{ .transferResponse = transfer_response_msg });

        // wait for file connection
        var file_conn = try file_channel.receive(rt);

        // reader buf for socket
        const read_buf = try self.allocator.create([4096]u8); // on heap
        errdefer self.allocator.destroy(read_buf);

        // temporary reader for handshake/init msgs
        var reader = file_conn.socket.?.reader(rt, read_buf);

        // token determines how handshake goes. if nonzero, this was indirect
        if (file_conn.token == 0) {
            const peer_init_msg = messages.PeerInit{
                .username = self.own_username,
                .type = @tagName(types.ConnectionType.F),
                .token = 0,
            };

            try file_conn.sendPeerInitMessage(rt, .{ .peerInit = peer_init_msg });
        } else {
            const pierce_firewall_msg = messages.PierceFireWall{
                .token = file_conn.token,
            };

            try file_conn.sendPeerInitMessage(rt, .{ .pierceFireWall = pierce_firewall_msg });
        }

        // read file transfer init
        const msg = try file_conn.readFileTransferInitMessage(&reader);
        std.log.debug("FileTransferInit received for {s}: token={d}", .{ self.username, msg.token });

        // tell the peer we have none of the file
        const file_offset_msg = messages.FileOffsetMessage{
            .offset = 0,
        };
        try file_conn.sendFileMessage(rt, .{ .fileOffset = file_offset_msg });

        // create a channel for the downloaded bytes
        const buf = try self.allocator.alloc(u8, transfer_request_msg.size);
        errdefer self.allocator.free(buf);
        const channel = try self.allocator.create(zio.Channel(u8));
        errdefer self.allocator.destroy(channel);
        channel.* = zio.Channel(u8).init(buf);

        // download task logic
        const DownloadTask = struct {
            fn run(runtime: *zio.Runtime, fconn: *FileConnection, allocator: std.mem.Allocator, rdr_buf: *[4096]u8, ch: *zio.Channel(u8), size: u64) void {
                // cleanup the stuff we use
                defer {
                    fconn.deinit(runtime);
                    allocator.destroy(fconn);
                    allocator.destroy(rdr_buf);
                    ch.close(.graceful);
                }

                // get reader in task
                var rdr = fconn.socket.?.reader(runtime, rdr_buf);

                // push bytes into channel one by one
                var remaining = size;
                while (remaining > 0) {
                    const byte = rdr.interface.takeByte() catch |err| {
                        std.log.err("Could not read from file connection: {}", .{err});
                        ch.close(.immediate);
                        return;
                    };
                    ch.trySend(byte) catch |err| {
                        std.log.err("Could not send to channel: {}", .{err});
                        return;
                    };
                    remaining -= 1;
                }
            }
        };

        // spawn task to feed channel
        const handle = try rt.spawn(DownloadTask.run, .{ rt, file_conn, self.allocator, read_buf, channel, transfer_request_msg.size });

        // return channel to caller
        return DownloadChannel{
            .size = transfer_request_msg.size,
            .buffer = buf,
            .channel = channel,
            .handle = handle,
        };
    }

    // Peer message parser.
    fn readResponse(self: *PeerConnection, reader: *zio.net.Stream.Reader) !messages.PeerMessage {
        // TODO: handle error when socket is closed

        // parse message header
        const payload_len = try reader.interface.takeInt(u32, .little);
        if (payload_len < 4) return error.InvalidMessage;
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
            41 => .{ .transferResponse = try messages.TransferResponseMessage.parse(self.allocator, &reader.interface, .uploadToPeer) }, // TODO: this does not support legacy TransferResponse for queuing downloads
            43 => .{ .queueUpload = try messages.QueueUploadMessage.parse(self.allocator, &reader.interface) },
            46 => .{ .uploadFailed = try messages.UploadFailedMessage.parse(self.allocator, &reader.interface) },
            50 => .{ .uploadDenied = try messages.UploadDeniedMessage.parse(self.allocator, &reader.interface) },
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

                    // convert internal share representation to protocol structure
                    const dirs = self.client.formatShares(&self.client.shared_dirs) catch |err| {
                        std.log.err("\tFailed to format shared directories: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(dirs);

                    const priv_dirs = self.client.formatShares(&self.client.shared_priv_dirs) catch |err| {
                        std.log.err("\tFailed to format shared private directories: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(priv_dirs);

                    const msg = messages.SharedFileListMessage{
                        .directories = dirs,
                        .private_directories = priv_dirs,
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

                    self.client.upload_queue.impl.mutex.lock();
                    const msg = messages.UserInfoMessage{
                        .description = self.client.user_info.description,
                        .picture = self.client.user_info.picture,
                        .queue_size = @intCast(self.client.upload_queue.impl.count),
                        .slots_free = (self.client.active_uploads.load(.seq_cst) < self.client.upload_slots),
                        .total_upload = self.client.upload_slots,
                        .upload_permitted = .everyone,
                    };
                    self.client.upload_queue.impl.mutex.unlock();

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
                            std.log.err("\tError sending transfer request in oneshot channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .transferResponse => |msg| {
                    std.log.debug("\tReceived transfer response from {s}: token {d}", .{ self.username, msg.token });
                    should_deinit = false;

                    // send response in oneshot channel, if someone is waiting
                    if (self.transfer_response_channels.get(msg.token)) |channel| {
                        channel.send(rt, msg) catch |err| {
                            std.log.err("\tError sending transfer response in oneshot channel: {}", .{err});
                            should_deinit = true;
                            continue;
                        };
                    }
                },
                .queueUpload => |msg| {
                    std.log.debug("\t{s} requests file '{s}'", .{ self.username, msg.filename });

                    // get real path in local filesystem
                    const dir_path = std.fs.path.dirnameWindows(msg.filename) orelse "";
                    const file_name = std.fs.path.basenameWindows(msg.filename);
                    const real_dir_path = self.client.shared_real_paths.get(dir_path) orelse {
                        // unknown path
                        self.sendPeerMessage(rt, .{
                            .uploadDenied = messages.UploadDeniedMessage{
                                .filename = msg.filename,
                                .reason = "File not shared.",
                            },
                        }) catch {};
                        continue;
                    };

                    // check target file exists
                    const real_dir = std.Io.Dir.openDirAbsolute(self.client.io, real_dir_path, .{}) catch {
                        self.sendPeerMessage(rt, .{ .uploadDenied = .{
                            .filename = msg.filename,
                            .reason = "File not shared.",
                        } }) catch {};
                        continue;
                    };
                    defer real_dir.close(self.client.io);
                    const stat = real_dir.statFile(self.client.io, file_name, .{}) catch {
                        self.sendPeerMessage(rt, .{ .uploadDenied = .{
                            .filename = msg.filename,
                            .reason = "File not shared.",
                        } }) catch {};
                        continue;
                    };

                    // build upload
                    const username = self.allocator.dupe(u8, self.username) catch continue;
                    const filename = self.allocator.dupe(u8, msg.filename) catch {
                        self.allocator.free(username);
                        continue;
                    };
                    const real_path = std.fs.path.join(self.allocator, &.{ real_dir_path, file_name }) catch {
                        self.allocator.free(username);
                        self.allocator.free(filename);
                        continue;
                    };
                    var upload = types.QueuedUpload{
                        .username = username,
                        .filename = filename,
                        .real_path = real_path,
                        .size = stat.size,
                    };

                    // send to the upload queue dispatcher
                    self.client.upload_queue.trySend(upload) catch {
                        // queue is full
                        upload.deinit(self.allocator);
                        self.sendPeerMessage(rt, .{
                            .uploadDenied = messages.UploadDeniedMessage{
                                .filename = msg.filename,
                                .reason = "Queue is full.",
                            },
                        }) catch {};
                        continue;
                    };
                },
                .uploadFailed => |msg| {
                    std.log.debug("\tReceived upload failure from {s}: {s}", .{ self.username, msg.filename });

                    // close oneshot channel, if someone is waiting
                    if (self.transfer_request_channel) |channel| {
                        channel.close(.graceful);
                    }
                },
                .uploadDenied => |msg| {
                    std.log.debug("\tReceived upload denied from {s}: File {s} | {s}", .{ self.username, msg.filename, msg.reason });

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
