const std = @import("std");
const types = @import("types.zig");

/// Represents a Soulseek server message. Enum value corresponds to the relevant message code.
pub const Message = union(enum(u32)) {
    login: LoginMessage = 1,
    setWaitPort: SetWaitPortMessage = 2,
    getPeerAddress: GetPeerAddressMessage = 3,
    connectToPeer: ConnectToPeerMessage = 18,
    messageUser: MessageUserMessage = 22,
    messageAcked: MessageAckedMessage = 23,
    fileSearch: FileSearchMessage = 26,
    uploadSpeed: UploadSpeedMessage = 121,

    // Returns the relevant message code based on the enum value.
    pub fn code(self: Message) u32 {
        return @intFromEnum(self);
    }

    // Returns the size of the underlying message. Returns an error if message is larger than u32 max value.
    pub fn size(self: Message) !u32 {
        // get size of underlying message
        const msg_size = switch (self) {
            inline else => |msg| calcSize(msg),
        };

        // check for overflow
        if (msg_size > std.math.maxInt(u32)) {
            return error.MessageTooLarge;
        }

        return @intCast(msg_size);
    }

    // Writes a message.
    pub fn write(self: Message, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, try self.size() + 4, .little); // message length as u32, add 4 for message code
        try writer.writeInt(u32, self.code(), .little); // message code as u32

        switch (self) {
            inline else => |msg| try msg.write(writer), // call underlying write function in relevant message
        }
    }
};

/// Represents server code 1, a message to login to the server.
pub const LoginMessage = struct {
    username: []const u8,
    password: []const u8,
    version: u32,
    hash: []const u8, // MD5 hash, but ASCII encoded. that's lame
    minor_version: u32,

    pub fn write(self: LoginMessage, writer: *std.Io.Writer) !void {
        try writeString(self.username, writer);
        try writeString(self.password, writer);
        try writer.writeInt(u32, self.version, .little);
        try writeString(self.hash, writer);
        try writer.writeInt(u32, self.minor_version, .little);
    }
};

/// Represents server code 2, a message to advertise our listener port. Does not support obfuscation.
pub const SetWaitPortMessage = struct {
    port: u32,

    pub fn write(self: SetWaitPortMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.port, .little);
    }
};

/// Represents server code 3, a message to get the address of a peer.
pub const GetPeerAddressMessage = struct {
    username: []const u8,

    pub fn write(self: GetPeerAddressMessage, writer: *std.Io.Writer) !void {
        try writeString(self.username, writer);
    }
};

/// Represents server code 18, a message to request connection to a peer.
pub const ConnectToPeerMessage = struct {
    token: u32,
    username: []const u8,
    type: []const u8,

    pub fn write(self: ConnectToPeerMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.token, .little);
        try writeString(self.username, writer);
        try writeString(self.type, writer);
    }
};

/// Represents server code 22, a message to represent a user direct message.
pub const MessageUserMessage = struct {
    username: []const u8,
    message: []const u8,

    pub fn write(self: MessageUserMessage, writer: *std.Io.Writer) !void {
        try writeString(self.username, writer);
        try writeString(self.message, writer);
    }
};

/// Represents server code 26, a message to represent a search query.
pub const FileSearchMessage = struct {
    token: u32,
    query: []const u8,

    pub fn write(self: FileSearchMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.token, .little);
        try writeString(self.query, writer);
    }
};

/// Represents server code 23, a message to acknowledge receipt of a user direct message.
pub const MessageAckedMessage = struct {
    message_id: u32,

    pub fn write(self: MessageAckedMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.message_id, .little);
    }
};

/// Represents server code 121, a message to report our upload speed.
pub const UploadSpeedMessage = struct {
    speed: u32,

    pub fn write(self: UploadSpeedMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.speed, .little);
    }
};

/// Represents a Soulseek server response. Enum value corresponds to the relevant message code.
pub const Response = union(enum(u32)) {
    login: LoginResponse = 1,
    getPeerAddress: GetPeerAddressResponse = 3,
    connectToPeer: ConnectToPeerResponse = 18,
    messageUser: MessageUserResponse = 22,
    roomList: RoomListResponse = 64,
    privilegedUsers: PrivilegedUsersResponse = 69,
    parentMinSpeed: ParentMinSpeedResponse = 83,
    parentSpeedRatio: ParentSpeedRatioResponse = 84,
    wishlistSearch: WishlistSearchResponse = 104,
    excludedSearchPhrases: ExcludedSearchPhrasesResponse = 160,

    // Returns the relevant message code based on the enum value.
    pub fn code(self: Response) u32 {
        return @intFromEnum(self);
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*resp| resp.deinit(allocator),
        }
    }
};

/// Represents a corresponding response to a LoginMessage.
pub const LoginResponse = struct {
    success: bool,
    greeting: ?[]const u8,
    ip_address: ?[4]u8,
    hash: ?[]const u8,
    is_supporter: ?bool,
    rejection_reason: ?[]const u8,
    rejection_detail: ?[]const u8,

    pub fn deinit(self: *LoginResponse, allocator: std.mem.Allocator) void {
        // free allocated strings
        if (self.greeting) |str| allocator.free(str);
        if (self.hash) |str| allocator.free(str);
        if (self.rejection_reason) |str| allocator.free(str);
        if (self.rejection_detail) |str| allocator.free(str);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator, payload_len: u32) !LoginResponse {
        var response = LoginResponse{
            .success = false,
            .greeting = null,
            .ip_address = null,
            .hash = null,
            .is_supporter = null,
            .rejection_reason = null,
            .rejection_detail = null,
        };

        response.success = (try reader.takeByte() == 1);

        if (response.success) {
            response.greeting = try readString(allocator, reader);
            response.ip_address = try readIP(reader);
            response.hash = try readString(allocator, reader);
            response.is_supporter = (try reader.takeByte() == 1);
        } else {
            response.rejection_reason = try readString(allocator, reader);
            // check if there are rejection details
            if (reader.seek - 4 < payload_len) {
                response.rejection_detail = try readString(allocator, reader);
            }
        }

        return response;
    }
};

/// Represents a GetPeerAddress response.
pub const GetPeerAddressResponse = struct {
    username: []const u8,
    ip: [4]u8,
    port: u32,
    obfuscation_type: u32,
    obfuscated_port: u16,

    pub fn deinit(self: *GetPeerAddressResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !GetPeerAddressResponse {
        return GetPeerAddressResponse{
            .username = try readString(allocator, reader),
            .ip = try readIP(reader),
            .port = try reader.takeInt(u32, .little),
            .obfuscation_type = try reader.takeInt(u32, .little),
            .obfuscated_port = try reader.takeInt(u16, .little),
        };
    }
};

/// Represents a ConnectToPeer response.
pub const ConnectToPeerResponse = struct {
    username: []const u8,
    type: []const u8,
    ip: [4]u8,
    port: u32,
    token: u32,
    privileged: bool,
    obfuscation_type: u32,
    obfuscated_port: u32,

    pub fn deinit(self: *ConnectToPeerResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.type);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !ConnectToPeerResponse {
        return ConnectToPeerResponse{
            .username = try readString(allocator, reader),
            .type = try readString(allocator, reader),
            .ip = try readIP(reader),
            .port = try reader.takeInt(u32, .little),
            .token = try reader.takeInt(u32, .little),
            .privileged = (try reader.takeByte() == 1),
            .obfuscation_type = try reader.takeInt(u32, .little),
            .obfuscated_port = try reader.takeInt(u32, .little),
        };
    }
};

/// Represents a MessageUser response.
pub const MessageUserResponse = struct {
    id: u32,
    timestamp: u32,
    username: []const u8,
    message: []const u8,
    new_message: bool,

    pub fn deinit(self: *MessageUserResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.message);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !MessageUserResponse {
        return MessageUserResponse{
            .id = try reader.takeInt(u32, .little),
            .timestamp = try reader.takeInt(u32, .little),
            .username = try readString(allocator, reader),
            .message = try readString(allocator, reader),
            .new_message = (try reader.takeByte() == 1),
        };
    }
};

/// Represents a RoomList response.
pub const RoomListResponse = struct {
    rooms: []Room,
    owned_private_rooms: []Room,
    unowned_private_rooms: []Room,
    operated_private_rooms: []Room,

    pub fn deinit(self: *RoomListResponse, allocator: std.mem.Allocator) void {
        for (self.rooms) |*room| room.deinit(allocator);
        allocator.free(self.rooms);
        for (self.owned_private_rooms) |*room| room.deinit(allocator);
        allocator.free(self.owned_private_rooms);
        for (self.unowned_private_rooms) |*room| room.deinit(allocator);
        allocator.free(self.unowned_private_rooms);
        for (self.operated_private_rooms) |*room| room.deinit(allocator);
        allocator.free(self.operated_private_rooms);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !RoomListResponse {
        return RoomListResponse{
            .rooms = try readRooms(reader, allocator, false),
            .owned_private_rooms = try readRooms(reader, allocator, false),
            .unowned_private_rooms = try readRooms(reader, allocator, false),
            .operated_private_rooms = try readRooms(reader, allocator, true), // operated private rooms do not share user count
        };
    }

    /// Helper function to read Rooms to a slice.
    fn readRooms(reader: *std.Io.Reader, allocator: std.mem.Allocator, skip_user_count: bool) ![]Room {
        const room_count = try reader.takeInt(u32, .little);
        const rooms = try allocator.alloc(Room, room_count);
        var rooms_parsed: usize = 0;
        errdefer {
            for (rooms[0..rooms_parsed]) |*room| {
                room.deinit(allocator);
            }
            allocator.free(rooms);
        }

        // first pass, add room names
        for (rooms) |*room| {
            room.*.name = try readString(allocator, reader);
            rooms_parsed += 1;
        }

        // second pass, set user count if needed
        if (!skip_user_count) {
            // room count again, discard
            _ = try reader.takeInt(u32, .little);
            for (rooms) |*room| {
                room.*.user_count = try reader.takeInt(u32, .little);
            }
        }

        return rooms;
    }
};

/// Represents a Room on the Soulseek network.
pub const Room = struct {
    name: []const u8,
    user_count: u32,

    pub fn deinit(self: *Room, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Represents a PrivilegedUsers response.
pub const PrivilegedUsersResponse = struct {
    users: [][]const u8,

    pub fn deinit(self: *PrivilegedUsersResponse, allocator: std.mem.Allocator) void {
        for (self.users) |user| allocator.free(user);
        allocator.free(self.users);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !PrivilegedUsersResponse {
        const user_count = try reader.takeInt(u32, .little);
        const users = try allocator.alloc([]const u8, user_count);
        var users_parsed: usize = 0;
        errdefer {
            for (users[0..users_parsed]) |user| allocator.free(user);
            allocator.free(users);
        }
        for (users) |*user| {
            user.* = try readString(allocator, reader);
            users_parsed += 1;
        }

        return PrivilegedUsersResponse{
            .users = users,
        };
    }
};

/// Represents a ParentMinSpeed response.
pub const ParentMinSpeedResponse = struct {
    speed: u32,

    pub fn deinit(self: *ParentMinSpeedResponse, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn parse(reader: *std.Io.Reader) !ParentMinSpeedResponse {
        return ParentMinSpeedResponse{
            .speed = try reader.takeInt(u32, .little),
        };
    }
};

/// Represents a ParentSpeedRatio response.
pub const ParentSpeedRatioResponse = struct {
    ratio: u32,

    pub fn deinit(self: *ParentSpeedRatioResponse, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn parse(reader: *std.Io.Reader) !ParentSpeedRatioResponse {
        return ParentSpeedRatioResponse{
            .ratio = try reader.takeInt(u32, .little),
        };
    }
};

/// Represents a WishlistSearch response.
pub const WishlistSearchResponse = struct {
    interval: u32,

    pub fn deinit(self: *WishlistSearchResponse, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn parse(reader: *std.Io.Reader) !WishlistSearchResponse {
        return WishlistSearchResponse{
            .interval = try reader.takeInt(u32, .little),
        };
    }
};

/// Represents an ExcludedSearchPhrases response.
pub const ExcludedSearchPhrasesResponse = struct {
    phrases: [][]const u8,

    pub fn deinit(self: *ExcludedSearchPhrasesResponse, allocator: std.mem.Allocator) void {
        for (self.phrases) |phrase| allocator.free(phrase);
        allocator.free(self.phrases);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !ExcludedSearchPhrasesResponse {
        const phrase_count = try reader.takeInt(u32, .little);
        const phrases = try allocator.alloc([]const u8, phrase_count);
        var phrases_parsed: usize = 0;
        errdefer {
            for (phrases[0..phrases_parsed]) |phrase| allocator.free(phrase);
            allocator.free(phrases);
        }
        for (phrases) |*phrase| {
            phrase.* = try readString(allocator, reader);
            phrases_parsed += 1;
        }

        return ExcludedSearchPhrasesResponse{
            .phrases = phrases,
        };
    }
};

/// Represents a Soulseek peer init message. These are generic. Enum value corresponds to the relevant message code.
pub const PeerMessage = union(enum(u32)) {
    getSharedFileList: EmptyMessage = 4,
    sharedFileList: SharedFileListMessage = 5,
    fileSearchResponse: FileSearchResponseMessage = 9,
    getUserInfo: EmptyMessage = 15,
    userInfo: UserInfoMessage = 16,
    transferRequest: TransferRequestMessage = 40,
    transferResponse: TransferResponseMessage = 41,
    queueUpload: QueueUploadMessage = 43,
    uploadFailed: UploadFailedMessage = 46,
    uploadDenied: UploadDeniedMessage = 50,

    pub fn deinit(self: *PeerMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*resp| resp.deinit(allocator),
        }
    }

    // Returns the relevant message code based on the enum value.
    pub fn code(self: PeerMessage) u32 {
        return @intFromEnum(self);
    }

    // Returns the size of the underlying message. Returns an error if message is larger than u32 max value.
    pub fn size(self: PeerMessage) !u32 {
        // get size of underlying message
        const msg_size = switch (self) {
            inline .transferResponse => |msg| msg.calcSize(), // transfer responses must have size calculated dynamically
            inline else => |msg| calcSize(msg),
        };

        // check for overflow
        if (msg_size > std.math.maxInt(u32)) {
            return error.MessageTooLarge;
        }

        return @intCast(msg_size);
    }

    // Writes a message.
    pub fn write(self: PeerMessage, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        switch (self) {
            inline .sharedFileList, .fileSearchResponse => |msg| try msg.write(allocator, writer), // zlib compressed, size unknown
            inline else => |msg| {
                try writer.writeInt(u32, try self.size() + 4, .little);
                try writer.writeInt(u32, self.code(), .little);
                try msg.write(writer);
            },
        }
    }
};

/// Represents peer code 5, a message containing files shared by a client.
pub const SharedFileListMessage = struct {
    directories: []SharedDirectory,
    private_directories: []SharedDirectory,

    pub fn deinit(self: *SharedFileListMessage, allocator: std.mem.Allocator) void {
        for (self.directories) |*dir| {
            dir.deinit(allocator);
        }
        allocator.free(self.directories);

        for (self.private_directories) |*dir| {
            dir.deinit(allocator);
        }
        allocator.free(self.private_directories);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader, payload_len: u32) !SharedFileListMessage {
        // read full compressed payload
        const compressed_len = payload_len - 4;
        const compressed = try reader.readAlloc(allocator, compressed_len);
        defer allocator.free(compressed);
        var fixed = std.Io.Reader.fixed(compressed);

        // message is zlib compressed
        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&fixed, .zlib, &buf);

        const dir_count = try decompressor.reader.takeInt(u32, .little);
        const directories = try allocator.alloc(SharedDirectory, dir_count);
        errdefer allocator.free(directories);
        for (directories) |*dir| {
            dir.* = try SharedDirectory.parse(allocator, &decompressor.reader);
            errdefer dir.deinit(allocator);
        }

        // official clients read u32 0
        _ = try decompressor.reader.takeByte();

        const priv_dir_count = try decompressor.reader.takeInt(u32, .little);
        const private_directories = try allocator.alloc(SharedDirectory, priv_dir_count);
        errdefer allocator.free(private_directories);
        for (private_directories) |*dir| {
            dir.* = try SharedDirectory.parse(allocator, &decompressor.reader);
            errdefer dir.deinit(allocator);
        }

        return SharedFileListMessage{
            .directories = directories,
            .private_directories = private_directories,
        };
    }

    pub fn write(self: SharedFileListMessage, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        // body is zlib compressed
        var intermediate_writer = try std.Io.Writer.Allocating.initCapacity(allocator, 9); // allocating writer, but compressor asserts that output buf > 8.
        defer intermediate_writer.deinit();

        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor = try std.compress.flate.Compress.init(&intermediate_writer.writer, &buf, .zlib, .level_6);

        try compressor.writer.writeInt(u32, @intCast(self.directories.len), .little);
        for (self.directories) |*dir| {
            try dir.write(&compressor.writer);
        }

        // official clients write u32 0
        try compressor.writer.writeInt(u32, 0, .little);

        try compressor.writer.writeInt(u32, @intCast(self.private_directories.len), .little);
        for (self.private_directories) |*dir| {
            try dir.write(&compressor.writer);
        }

        try compressor.writer.flush();

        const compressed = try intermediate_writer.toOwnedSlice();
        defer allocator.free(compressed);

        // write header, size is now known
        try writer.writeInt(u32, @intCast(compressed.len + 4), .little);
        try writer.writeInt(u32, 5, .little);

        // write body
        try writer.writeAll(compressed);
    }
};

/// Represents peer code 9, a message containing a response to a file search.
pub const FileSearchResponseMessage = struct {
    username: []const u8,
    token: u32,
    files: []SharedFile,
    slots_free: bool,
    avg_speed: u32,
    queue_len: u32,
    private_files: []SharedFile,

    pub fn deinit(self: *const FileSearchResponseMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.username);

        for (self.files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(self.files);

        for (self.private_files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(self.private_files);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader, payload_len: u32) !FileSearchResponseMessage {
        // read full compressed payload
        const compressed_len = payload_len - 4;
        const compressed = try reader.readAlloc(allocator, compressed_len);
        defer allocator.free(compressed);
        var fixed = std.Io.Reader.fixed(compressed);

        // message is zlib compressed
        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&fixed, .zlib, &buf);

        const username = try readString(allocator, &decompressor.reader);
        errdefer allocator.free(username);
        const token = try decompressor.reader.takeInt(u32, .little);

        const file_count = try decompressor.reader.takeInt(u32, .little);
        const files = try allocator.alloc(SharedFile, file_count);
        var files_parsed: usize = 0;
        errdefer {
            for (files[0..files_parsed]) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        for (files) |*file| {
            file.* = try SharedFile.parse(allocator, &decompressor.reader);
            files_parsed += 1;
        }

        const slots_free = (try decompressor.reader.takeByte() == 1);
        const avg_speed = try decompressor.reader.takeInt(u32, .little);
        const queue_len = try decompressor.reader.takeInt(u32, .little);

        // official clients read u32 0
        _ = try decompressor.reader.takeInt(u32, .little);

        const priv_file_count = try decompressor.reader.takeInt(u32, .little);
        const private_files = try allocator.alloc(SharedFile, priv_file_count);
        var priv_files_parsed: usize = 0;
        errdefer {
            for (private_files[0..priv_files_parsed]) |*file| {
                file.deinit(allocator);
            }
            allocator.free(private_files);
        }
        for (private_files) |*file| {
            file.* = try SharedFile.parse(allocator, &decompressor.reader);
            priv_files_parsed += 1;
        }

        return FileSearchResponseMessage{
            .username = username,
            .token = token,
            .files = files,
            .slots_free = slots_free,
            .avg_speed = avg_speed,
            .queue_len = queue_len,
            .private_files = private_files,
        };
    }

    pub fn write(self: FileSearchResponseMessage, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        // body is zlib compressed
        var intermediate_writer = try std.Io.Writer.Allocating.initCapacity(allocator, 9); // allocating writer, but compressor asserts that output buf > 8.
        defer intermediate_writer.deinit();

        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor = try std.compress.flate.Compress.init(&intermediate_writer.writer, &buf, .zlib, .level_6);

        try writeString(self.username, &compressor.writer);
        try compressor.writer.writeInt(u32, self.token, .little);

        try compressor.writer.writeInt(u32, @intCast(self.files.len), .little);
        for (self.files) |*file| {
            try file.write(&compressor.writer);
        }

        try writer.writeByte(@intFromBool(self.slots_free));
        try compressor.writer.writeInt(u32, self.avg_speed, .little);
        try compressor.writer.writeInt(u32, self.queue_len, .little);

        // official clients write u32 0
        try compressor.writer.writeInt(u32, 0, .little);

        try compressor.writer.writeInt(u32, @intCast(self.private_files.len), .little);
        for (self.private_files) |*file| {
            try file.write(&compressor.writer);
        }

        try compressor.writer.flush();

        const compressed = try intermediate_writer.toOwnedSlice();
        defer allocator.free(compressed);

        // write header, size is now known
        try writer.writeInt(u32, @intCast(compressed.len + 4), .little);
        try writer.writeInt(u32, 9, .little);

        // write body
        try writer.writeAll(compressed);
    }
};

/// Represents metadata for a shared directory. Used in SharedFileListMessage.
pub const SharedDirectory = struct {
    name: []const u8,
    files: []SharedFile,

    pub fn deinit(self: *SharedDirectory, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(self.files);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !SharedDirectory {
        const name = try readString(allocator, reader);
        errdefer allocator.free(name);

        const file_count = try reader.takeInt(u32, .little);
        const files = try allocator.alloc(SharedFile, file_count);
        var files_parsed: usize = 0;
        errdefer {
            for (files[0..files_parsed]) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        for (files) |*file| {
            file.* = try SharedFile.parse(allocator, reader);
            files_parsed += 1;
        }

        return SharedDirectory{
            .name = name,
            .files = files,
        };
    }

    pub fn write(self: SharedDirectory, writer: *std.Io.Writer) !void {
        try writeString(self.name, writer);
        try writer.writeInt(u32, @intCast(self.files.len), .little);
        for (self.files) |*file| {
            try file.write(writer);
        }
    }
};

/// Represents metadata for a shared file. Used in SharedDirectory.
pub const SharedFile = struct {
    code: u8,
    name: []const u8,
    size: u64,
    extension: []const u8,
    attributes: []FileAttributes,

    pub fn deinit(self: *SharedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.extension);
        allocator.free(self.attributes);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !SharedFile {
        const code = try reader.takeByte();
        const name = try readString(allocator, reader);
        errdefer allocator.free(name);
        const size = try reader.takeInt(u64, .little);
        const extension = try readString(allocator, reader);
        errdefer allocator.free(extension);

        const attribute_count = try reader.takeInt(u32, .little);
        const attributes = try allocator.alloc(FileAttributes, attribute_count);
        errdefer allocator.free(attributes);
        for (attributes) |*attribute| {
            attribute.*.code = try reader.takeInt(u32, .little);
            attribute.*.value = try reader.takeInt(u32, .little);
        }

        return SharedFile{
            .code = code,
            .name = name,
            .size = size,
            .extension = extension,
            .attributes = attributes,
        };
    }

    pub fn write(self: SharedFile, writer: *std.Io.Writer) !void {
        try writer.writeByte(self.code);
        try writeString(self.name, writer);
        try writer.writeInt(u64, self.size, .little);
        try writeString(self.extension, writer);
        try writer.writeInt(u32, @intCast(self.attributes.len), .little);

        for (self.attributes) |*attribute| {
            try writer.writeInt(u32, attribute.code, .little);
            try writer.writeInt(u32, attribute.value, .little);
        }
    }
};

/// Represents attributes a SharedFile might have.
pub const FileAttributes = struct {
    code: u32,
    value: u32,
};

/// Represents peer code 16, a message containing rich user information.
pub const UserInfoMessage = struct {
    description: []const u8,
    picture: ?[]const u8,
    total_upload: u32,
    queue_size: u32,
    slots_free: bool,
    upload_permitted: UploadPermissions,

    const UploadPermissions = enum(u32) {
        no_one = 0,
        everyone = 1,
        users_in_list = 2,
        permitted_users = 3,
    };

    pub fn deinit(self: *UserInfoMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        if (self.picture) |p| allocator.free(p);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader, start_seek: usize, payload_len: u32) !UserInfoMessage {
        const description = try readString(allocator, reader);
        const has_picture = (try reader.takeByte() == 1);
        var picture: ?[]const u8 = null;
        if (has_picture) {
            picture = try readString(allocator, reader);
        }
        const total_upload = try reader.takeInt(u32, .little);
        const queue_size = try reader.takeInt(u32, .little);
        const slots_free = (try reader.takeByte() == 1);
        var upload_permitted = UploadPermissions.everyone; // default to everyone
        if (reader.seek - start_seek < payload_len) {
            upload_permitted = @enumFromInt(try reader.takeInt(u32, .little));
        }

        return UserInfoMessage{
            .description = description,
            .picture = picture,
            .total_upload = total_upload,
            .queue_size = queue_size,
            .slots_free = slots_free,
            .upload_permitted = upload_permitted,
        };
    }

    pub fn write(self: UserInfoMessage, writer: *std.Io.Writer) !void {
        try writeString(self.description, writer);
        try writer.writeByte(@intFromBool(self.picture != null));
        if (self.picture) |p| try writeString(p, writer);
        try writer.writeInt(u32, self.total_upload, .little);
        try writer.writeInt(u32, self.queue_size, .little);
        try writer.writeByte(@intFromBool(self.slots_free));
        try writer.writeInt(u32, @intFromEnum(self.upload_permitted), .little);
    }
};

/// Represents peer code 40, a message to initiate a transfer.
pub const TransferRequestMessage = struct {
    direction: TransferDirection,
    token: u32,
    filename: []const u8,
    size: u64,

    pub fn deinit(self: *TransferRequestMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !TransferRequestMessage {
        const direction: TransferDirection = @enumFromInt(try reader.takeInt(u32, .little));
        const token = try reader.takeInt(u32, .little);
        const filename = try readString(allocator, reader);
        const size = if (direction == .uploadToPeer) try reader.takeInt(u64, .little) else 0;

        return TransferRequestMessage{
            .direction = direction,
            .token = token,
            .filename = filename,
            .size = size,
        };
    }

    pub fn write(self: TransferRequestMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, @intFromEnum(self.direction), .little);
        try writer.writeInt(u32, self.token, .little);
        try writeString(self.filename, writer);
        if (self.direction == .uploadToPeer) try writer.writeInt(u64, self.size, .little);
    }
};

/// Represents peer code 41, a message to respond to a transfer.
pub const TransferResponseMessage = struct {
    token: u32,
    allowed: bool,
    size: u64,
    reason: ?[]const u8,
    direction: TransferDirection,

    pub fn deinit(self: *TransferResponseMessage, allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
    }

    pub fn calcSize(self: TransferResponseMessage) usize {
        var size: usize = 4 + 1; // u32 (token) + u8 (bool)
        if (self.direction == .downloadFromPeer and self.allowed) size += 8; // u64 (size)
        if (self.reason) |reason| size += 4 + reason.len; // string (u32 len + []u8 data)

        return size;
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader, direction: TransferDirection) !TransferResponseMessage {
        const token = try reader.takeInt(u32, .little);
        const allowed = (try reader.takeByte() == 1);
        const size = if (direction == .downloadFromPeer and allowed) try reader.takeInt(u64, .little) else 0;
        const reason = if (!allowed) try readString(allocator, reader) else null;

        return TransferResponseMessage{
            .token = token,
            .allowed = allowed,
            .size = size,
            .reason = reason,
            .direction = direction,
        };
    }

    pub fn write(self: TransferResponseMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.token, .little);
        try writer.writeByte(@intFromBool(self.allowed));
        if (self.direction == .downloadFromPeer and self.allowed) try writer.writeInt(u64, self.size, .little);
        if (self.reason) |reason| try writeString(reason, writer);
    }
};

// Represents direction for TransferRequest and TransferResponse.
const TransferDirection = enum(u32) {
    downloadFromPeer = 0,
    uploadToPeer = 1,
};

/// Represents peer code 43, a message to queue an upload.
pub const QueueUploadMessage = struct {
    filename: []const u8,

    pub fn deinit(self: *QueueUploadMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !QueueUploadMessage {
        const filename = try readString(allocator, reader);

        return QueueUploadMessage{
            .filename = filename,
        };
    }

    pub fn write(self: QueueUploadMessage, writer: *std.Io.Writer) !void {
        try writeString(self.filename, writer);
    }
};

/// Represents peer code 46, a message to queue an upload.
pub const UploadFailedMessage = struct {
    filename: []const u8,

    pub fn deinit(self: *UploadFailedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !UploadFailedMessage {
        const filename = try readString(allocator, reader);

        return UploadFailedMessage{
            .filename = filename,
        };
    }

    pub fn write(self: UploadFailedMessage, writer: *std.Io.Writer) !void {
        try writeString(self.filename, writer);
    }
};

/// Represents peer code 46, a message to queue an upload.
pub const UploadDeniedMessage = struct {
    filename: []const u8,
    reason: []const u8,

    pub fn deinit(self: *UploadDeniedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.reason);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !UploadDeniedMessage {
        const filename = try readString(allocator, reader);
        const reason = try readString(allocator, reader);

        return UploadDeniedMessage{
            .filename = filename,
            .reason = reason,
        };
    }

    pub fn write(self: UploadDeniedMessage, writer: *std.Io.Writer) !void {
        try writeString(self.filename, writer);
        try writeString(self.reason, writer);
    }
};

/// Represents a Soulseek peer init message. These are generic. Enum value corresponds to the relevant message code.
pub const PeerInitMessage = union(enum(u8)) {
    pierceFireWall: PierceFireWall = 0,
    peerInit: PeerInit = 1,

    // Returns the relevant message code based on the enum value.
    pub fn code(self: PeerInitMessage) u8 {
        return @intFromEnum(self);
    }

    // Returns the size of the underlying message. Returns an error if message is larger than u32 max value.
    pub fn size(self: PeerInitMessage) !u32 {
        // get size of underlying message
        const msg_size = switch (self) {
            inline else => |msg| calcSize(msg),
        };

        // check for overflow
        if (msg_size > std.math.maxInt(u32)) {
            return error.MessageTooLarge;
        }

        return @intCast(msg_size);
    }

    // Writes a message.
    pub fn write(self: PeerInitMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, try self.size() + 1, .little); // message length as u32, add 1 for message code
        try writer.writeByte(self.code()); // message code as u8

        switch (self) {
            inline else => |msg| try msg.write(writer), // call underlying write function in relevant message
        }
    }
};

/// Represents a generic peer init message, PierceFireWall. The message and response are the same.
pub const PierceFireWall = struct {
    token: u32,

    pub fn deinit(self: *PierceFireWall, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn parse(reader: *std.Io.Reader) !PierceFireWall {
        return PierceFireWall{
            .token = try reader.takeInt(u32, .little),
        };
    }

    pub fn write(self: PierceFireWall, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.token, .little);
    }
};

/// Represents a generic peer init message, PeerInit. The message and response are the same.
pub const PeerInit = struct {
    username: []const u8,
    type: []const u8,
    token: u32 = 0,

    pub fn deinit(self: *PeerInit, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.type);
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !PeerInit {
        return PeerInit{
            .username = try readString(allocator, reader),
            .type = try readString(allocator, reader),
            .token = try reader.takeInt(u32, .little),
        };
    }

    pub fn write(self: PeerInit, writer: *std.Io.Writer) !void {
        try writeString(self.username, writer);
        try writeString(self.type, writer);
        try writer.writeInt(u32, self.token, .little);
    }
};

/// Represents a file connection message. Enum value corresponds to the relevant message code.
pub const FileMessage = union(enum(u32)) {
    fileTransferInit: FileTransferInitMessage = 1,
    fileOffset: FileOffsetMessage = 2,

    // Writes a message.
    pub fn write(self: FileMessage, writer: *std.Io.Writer) !void {
        // no length and message code

        switch (self) {
            inline else => |msg| try msg.write(writer), // call underlying write function in relevant message
        }
    }
};

/// Represents a message to initiate an upload over a file connection.
pub const FileTransferInitMessage = struct {
    token: u32,

    pub fn parse(reader: *std.Io.Reader) !FileTransferInitMessage {
        const token = try reader.takeInt(u32, .little);

        return FileTransferInitMessage{
            .token = token,
        };
    }

    pub fn write(self: FileTransferInitMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, self.token, .little);
    }
};

/// Represents a message to tell a peer how many bytes we have downloaded over a file connection.
pub const FileOffsetMessage = struct {
    offset: u64,

    pub fn parse(reader: *std.Io.Reader) !FileOffsetMessage {
        const offset = try reader.takeInt(u64, .little);

        return FileOffsetMessage{
            .offset = offset,
        };
    }

    pub fn write(self: FileOffsetMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u64, self.offset, .little);
    }
};

/// Represents a message with an empty body. Allows for messages containing no fields to be generically handled.
pub const EmptyMessage = struct {
    pub fn deinit(self: *EmptyMessage, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !EmptyMessage {
        _ = allocator;
        _ = reader;
        return EmptyMessage{};
    }

    pub fn write(self: EmptyMessage, writer: *std.Io.Writer) !void {
        _ = self;
        _ = writer;
    }
};

/// Helper function to write a string by writing it's length as u32, then bytes.
fn writeString(str: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeInt(u32, @intCast(str.len), .little);
    try writer.writeAll(str);
}

/// Helper function to read an IP address.
fn readIP(reader: *std.Io.Reader) ![4]u8 {
    var result = [4]u8{ 0x00, 0x00, 0x00, 0x00 };
    for (0..4) |i| {
        result[3 - i] = try reader.takeByte();
    }
    return result;
}

/// Helper function to read a string with a prefixed u32 length from a reader.
fn readString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const len = try reader.takeInt(u32, .little);
    return try reader.readAlloc(allocator, len);
}

/// Helper function to calculate the size of a message.
fn calcSize(msg: anytype) usize {
    const info = @typeInfo(@TypeOf(msg));

    // ensure this is a struct before we calculate the size
    if (info != .@"struct") {
        @compileError("calcSize can only be used with structs.");
    }

    var size: usize = 0;

    // iterate over fields in the struct and add their sizes to the sum
    inline for (info.@"struct".fields) |field| {
        const value = @field(msg, field.name);
        size += switch (@typeInfo(field.type)) {
            .bool => 1, // bool is u8 in slsk protocol
            .int => @sizeOf(field.type),
            .@"enum" => |e| @sizeOf(e.tag_type),
            .pointer => 4 + value.len, // we're gonna say this is a string, it's 4 (u32 len) + data.len
            .optional => |opt| 1 + blk: { // optionals are used when the protocol has an optional field. presence is denoted by bool, +1 byte
                if (value) |v| {
                    break :blk switch (@typeInfo(opt.child)) {
                        .bool => 1, // bool is u8 in slsk protocol
                        .int => @sizeOf(opt.child),
                        .@"enum" => |e| @sizeOf(e.tag_type),
                        .pointer => 4 + v.len, // string: 4 bytes (u32 len) + data.len
                        else => @compileError("Unsupported optional type: " ++ @typeName(opt.child)),
                    };
                } else {
                    break :blk 0; // optional has no value
                }
            },
            else => @compileError("Type contains an unhandled field type: " ++ @typeName(field.type) ++ ". Add support for this type."),
        };
    }

    return size;
}

// Miscellaneous test cases to validate implementation progress //
const expect = std.testing.expect;
test "getSize works for LoginMessage" {
    const login_msg = LoginMessage{
        .hash = "d51c9a7e9353746a6020f9602d452929",
        .minor_version = 1,
        .version = 1,
        .username = "username",
        .password = "password",
    };

    const calculated_size = calcSize(login_msg);

    // hash size == 36 (u32 + [32]u8)
    // minor_version size == 4 (u32)
    // version size == 4 (u32)
    // username size == 12 (u32 + [8]u8)
    // password size == 12 (u32 + [8]u8)
    try expect(calculated_size == 68);
}
