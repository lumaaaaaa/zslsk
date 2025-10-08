const std = @import("std");
const zslsk = @import("zslsk");

// constants
const HOST: []const u8 = "server.slsknet.org";
const PORT: u16 = 2242;

// zslsk test application entrypoint
pub fn main() !void {
    // create general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // initialize zslsk client
    var client = zslsk.Client.init(gpa.allocator());
    defer client.deinit();

    print("[info] attempting login\n", .{});
    try client.connect(HOST, PORT, "lzma", "nope");
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
