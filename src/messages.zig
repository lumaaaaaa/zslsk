const std = @import("std");
const types = @import("types.zig");

/// Represents a Soulseek message. Enum value corresponds to the relevant message code.
pub const Message = union(enum(u32)) {
    login: LoginMessage = 1,

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

/// Represents a Soulseek response. Enum value corresponds to the relevant message code.
pub const Response = union(enum(u32)) {
    login: LoginResponse = 1,
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

/// Represents a corresponding response to a LoginMessage.
pub const LoginResponse = struct {
    success: bool,
    greeting: ?[]const u8,
    ip_address: ?u32,
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
            response.ip_address = try reader.takeInt(u32, .little);
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

/// Helper function to write a string by writing it's length as u32, then bytes.
fn writeString(str: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeInt(u32, @intCast(str.len), .little);
    try writer.writeAll(str);
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
            .int => @sizeOf(field.type),
            .pointer => 4 + value.len, // we're gonna say this is a string, it's 4 (u32 len) + data.len
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
