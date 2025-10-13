const std = @import("std");
const zslsk = @import("zslsk");

// constants
const HOST: []const u8 = "server.slsknet.org";
const PORT: u16 = 2242;
const LISTEN_PORT: u16 = 22340;

const Command = enum {
    userinfo,
    exit, // exits the application
};

// zslsk test application entrypoint
pub fn main() !void {
    // create general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // initialize zslsk client
    var client = zslsk.Client.init(allocator);
    defer client.deinit();

    print("[input] username: ", .{});
    const username = try readStdinLine(allocator);
    defer allocator.free(username);
    print("[input] password: ", .{});
    const password = try readStdinLine(allocator);
    defer allocator.free(password);

    try client.connect(HOST, PORT, username, password, LISTEN_PORT);

    print("[info] login successful.\n", .{});
    while (true) {
        print("> ", .{});

        const line = try readStdinLine(allocator);
        defer allocator.free(line);

        var it = std.mem.splitScalar(u8, line, ' ');
        if (it.next()) |cmd_str| {
            const cmd_or_null = std.meta.stringToEnum(Command, cmd_str);

            if (cmd_or_null) |cmd| {
                switch (cmd) {
                    Command.userinfo => {
                        const user_or_null = it.next();

                        if (user_or_null) |user| {
                            const user_info = client.getUserInfo(user) catch |err| {
                                std.log.debug("likely could not connect to user. error: {}", .{err});
                                continue;
                            };
                            print("{s}: {s}\n", .{ user, user_info.description });
                        }
                    },
                    Command.exit => break,
                }
            } else {
                print("Unknown command.\n", .{});
            }
        }
    }

    print("[info] shutting down...", .{});
}

// helper function to print to stdout
fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    stdout.print(fmt, args) catch |err| {
        std.debug.print("Failed to print string to stdout: .{}\n", .{err});
    };
    stdout.flush() catch |err| {
        std.debug.print("Failed to flush stdout: .{}\n", .{err});
    };
}

/// helper function to read a single line from stdin
pub fn readStdinLine(allocator: std.mem.Allocator) ![]const u8 {
    var stdin_buffer: [64]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin.interface;

    // read a line from stdin
    const line = try reader.takeDelimiterExclusive('\n');

    // return a copy
    return allocator.dupe(u8, line);
}
