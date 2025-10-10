const std = @import("std");
const types = @import("types.zig");

/// Represents a Soulseek server message. Enum value corresponds to the relevant message code.
pub const Message = union(enum(u32)) {
    login: LoginMessage = 1,
    setWaitPort: SetWaitPortMessage = 2,
    connectToPeer: ConnectToPeerMessage = 18,
    messageUser: MessageUserMessage = 22,

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

/// Represents a Soulseek server response. Enum value corresponds to the relevant message code.
pub const Response = union(enum(u32)) {
    login: LoginResponse = 1,
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
    rooms: std.ArrayList(types.Room),
    owned_private_rooms: std.ArrayList(types.Room),
    unowned_private_rooms: std.ArrayList(types.Room),
    operated_private_rooms: std.ArrayList(types.Room),

    pub fn deinit(self: *RoomListResponse, allocator: std.mem.Allocator) void {
        self.rooms.deinit(allocator);
        self.owned_private_rooms.deinit(allocator);
        self.unowned_private_rooms.deinit(allocator);
        self.operated_private_rooms.deinit(allocator);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !RoomListResponse {
        return RoomListResponse{
            .rooms = try readRooms(reader, allocator, false),
            .owned_private_rooms = try readRooms(reader, allocator, false),
            .unowned_private_rooms = try readRooms(reader, allocator, false),
            .operated_private_rooms = try readRooms(reader, allocator, true), // operated private rooms do not share user count
        };
    }

    /// Helper function to read Rooms to an ArrayList.
    fn readRooms(reader: *std.Io.Reader, allocator: std.mem.Allocator, skip_user_count: bool) !std.ArrayList(types.Room) {
        var room_count = try reader.takeInt(u32, .little);
        var result = try std.ArrayList(types.Room).initCapacity(allocator, room_count);

        // first, add rooms with names
        for (0..room_count) |_| {
            // add room with placeholder count
            result.appendAssumeCapacity(types.Room{
                .name = try readString(allocator, reader),
                .user_count = 0, // will be set in second pass
            });
        }

        // then, set user count if needed
        if (!skip_user_count) {
            room_count = try reader.takeInt(u32, .little); // read it again, server supplies it once more
            for (result.items) |*room| {
                // update the user count with the actual value on each
                room.user_count = try reader.takeInt(u32, .little);
            }
        }

        return result;
    }
};

/// Represents a PrivilegedUsers response.
pub const PrivilegedUsersResponse = struct {
    users: std.ArrayList([]u8),

    pub fn deinit(self: *PrivilegedUsersResponse, allocator: std.mem.Allocator) void {
        self.users.deinit(allocator);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !PrivilegedUsersResponse {
        const user_count = try reader.takeInt(u32, .little);

        var response = PrivilegedUsersResponse{
            .users = try std.ArrayList([]u8).initCapacity(allocator, user_count),
        };

        for (0..user_count) |_| {
            const username = try readString(allocator, reader);
            response.users.appendAssumeCapacity(username);
        }

        return response;
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
    phrases: std.ArrayList([]u8),

    pub fn deinit(self: *ExcludedSearchPhrasesResponse, allocator: std.mem.Allocator) void {
        self.phrases.deinit(allocator);
    }

    pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !ExcludedSearchPhrasesResponse {
        const phrase_count = try reader.takeInt(u32, .little);

        var response = ExcludedSearchPhrasesResponse{
            .phrases = try std.ArrayList([]u8).initCapacity(allocator, phrase_count),
        };

        for (0..phrase_count) |_| {
            const phrase = try readString(allocator, reader);
            response.phrases.appendAssumeCapacity(phrase);
        }

        return response;
    }
};

/// Represents a Soulseek peer init message. These are generic. Enum value corresponds to the relevant message code.
pub const PeerMessage = union(enum(u32)) {
    sharedFileList: SharedFileListMessage = 5,
    userInfo: UserInfoMessage = 16,

    // Returns the relevant message code based on the enum value.
    pub fn code(self: PeerMessage) u32 {
        return @intFromEnum(self);
    }

    // Returns the size of the underlying message. Returns an error if message is larger than u32 max value.
    pub fn size(self: PeerMessage) !u32 {
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
    pub fn write(self: PeerMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, try self.size() + 4, .little); // message length as u32, add 4 for message code
        try writer.writeInt(u32, self.code(), .little); // message code as u32

        switch (self) {
            inline else => |msg| try msg.write(writer), // call underlying write function in relevant message
        }
    }
};

/// Represents peer code 5, a message containing files shared by a client.
pub const SharedFileListMessage = struct {
    data: []const u8,

    pub fn write(self: SharedFileListMessage, writer: *std.Io.Writer) !void {
        try writeString(self.data, writer);
    }
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

/// Represents a Soulseek server response. Enum value corresponds to the relevant message code.
pub const PeerResponse = union(enum(u32)) {
    getSharedFileList: EmptyMessage = 4,
    userInfo: EmptyMessage = 15,

    // Returns the relevant message code based on the enum value.
    pub fn code(self: PeerResponse) u32 {
        return @intFromEnum(self);
    }

    pub fn deinit(self: *PeerResponse, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*resp| resp.deinit(allocator),
        }
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

    pub fn write(self: PeerInit, writer: *std.Io.Writer) !void {
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
            .optional => |opt| blk: {
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
