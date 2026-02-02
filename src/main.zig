const std = @import("std");
const zslsk = @import("zslsk");
const zio = @import("zio");

// constants
const HOST: []const u8 = "server.slsknet.org";
const PORT: u16 = 2242;
const LISTEN_PORT: u16 = 22340;

const Command = enum {
    msg, // sends a message to a target user (ex. msg <username> <content>)
    userinfo, // retrieves user info for a target username (ex. userinfo <username>)
    exit, // exits the application
};

// zslsk test application entrypoint
pub fn main() !void {
    // create general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // create zio runtime
    var rt = try zio.Runtime.init(allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    print(rt, "[input] username: ", .{});
    const username = try readStdinLine(rt, allocator);
    defer allocator.free(username);
    print(rt, "[input] password: ", .{});
    const password = try readStdinLine(rt, allocator);
    defer allocator.free(password);

    // initialize zslsk client
    var client = try zslsk.Client.init(allocator);
    defer client.deinit();

    // run application inside zio runtime
    var task = try rt.spawn(app, .{ rt, &client, allocator, username, password });
    try task.join(rt);

    print(rt, "[info] shutting down...", .{});
}

fn app(rt: *zio.Runtime, client: *zslsk.Client, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !void {
    var client_group: zio.Group = .init;
    defer client_group.cancel(rt);

    try client_group.spawn(rt, runClient, .{ client, rt, username, password });

    // kinda a hack, but sleep without blocking the runtime to allow connection to become established
    while (client.connection_state.load(.seq_cst) != .connected) {
        try rt.sleep(.fromMilliseconds(10));
    }

    print(rt, "[info] login successful.\n", .{});

    while (true) {
        print(rt, "> ", .{});

        const line = try readStdinLine(rt, allocator);
        defer allocator.free(line);

        var it = std.mem.splitScalar(u8, line, ' ');
        if (it.next()) |cmd_str| {
            const cmd_or_null = std.meta.stringToEnum(Command, cmd_str);

            if (cmd_or_null) |cmd| {
                switch (cmd) {
                    Command.msg => {
                        const user = it.next() orelse {
                            print(rt, "[error] syntax: msg <username> <content>\n", .{});
                            continue;
                        };

                        const content = it.rest();
                        if (content.len == 0) {
                            print(rt, "[error] syntax: msg <username> <content>\n", .{});
                            continue;
                        }

                        client.messageUser(rt, user, content) catch |err| {
                            std.log.err("Could not send message to user: {}", .{err});
                            continue;
                        };
                        print(rt, "Message sent.\n", .{});
                    },
                    Command.userinfo => {
                        const user = it.next() orelse {
                            print(rt, "[error] syntax: userinfo <username>\n", .{});
                            continue;
                        };

                        const user_info = client.getUserInfo(rt, user) catch |err| {
                            std.log.err("likely could not connect to user. error: {}", .{err});
                            continue;
                        };

                        print(rt, "{s}: {s}\n", .{ user, user_info.description });
                    },
                    Command.exit => break,
                }
            } else {
                print(rt, "[error] unknown command.\n", .{});
            }
        }
    }
}

/// Begins running the client.
fn runClient(client: *zslsk.Client, rt: *zio.Runtime, username: []const u8, password: []const u8) void {
    client.run(rt, HOST, PORT, username, password, LISTEN_PORT) catch |err| {
        std.log.err("Client error: {}", .{err});
    };
}

/// Helper function to non-blocking print to stdout.
fn print(rt: *zio.Runtime, comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = zio.File.fromFd(std.posix.STDOUT_FILENO).writer(rt, &stdout_buffer);
    const writer_interface = &stdout_writer.interface;

    writer_interface.print(fmt, args) catch |err| {
        std.debug.print("Failed to print string to stdout: .{}\n", .{err});
    };
    writer_interface.flush() catch |err| {
        std.debug.print("Failed to flush stdout: .{}\n", .{err});
    };
}

/// Helper function to non-blocking read a single line from stdin.
pub fn readStdinLine(rt: *zio.Runtime, allocator: std.mem.Allocator) ![]const u8 {
    var stdin_buffer: [128]u8 = undefined;
    var stdin_reader = zio.File.fromFd(std.posix.STDIN_FILENO).reader(rt, &stdin_buffer);
    const reader_interface = &stdin_reader.interface;

    // read a line from stdin
    const line = try reader_interface.takeDelimiterExclusive('\n');

    // return a copy
    return allocator.dupe(u8, line);
}
