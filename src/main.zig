const std = @import("std");
const zslsk = @import("zslsk");
const zio = @import("zio");

// constants
const HOST: []const u8 = "server.slsknet.org";
const PORT: u16 = 2242;
const LISTEN_PORT: u16 = 2234;
const DEFAULT_TERM_WIDTH: u16 = 80;

const Command = enum {
    addlike, // adds a "like" entry to user profile interests (ex. addlike <entry>)
    rmlike, // removes a "like" entry from user profile interests (ex. rmlike <entry>)
    addhate, // adds a "hate" entry to user profile interests (ex. addhate <entry>)
    rmhate, // removes a "hate" entry from user profile interests (ex. rmhate <entry>)
    download, // downloads a target file from a target username (ex. download <username> <filename>)
    filelist, // retrieves file list for a target username (ex. filelist <username>)
    msg, // sends a message to a target user (ex. msg <username> <content>)
    search, // searches network for files matching a target query (ex. search <query>)
    setbio, // sets biography for user profile (ex. setbio <content>)
    setpic, // sets picture for user profile. argument can be omitted to unset (ex. setpic <path to pic or null>)
    share, // adds a local directory to the share list (ex. share <abs path>)
    userinfo, // retrieves user info for a target username (ex. userinfo <username>)
    exit, // exits the application
};

// zslsk test application entrypoint
pub fn main(init: std.process.Init) !void {
    // get juicy main args
    const io = init.io;
    const allocator = init.gpa;

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
    var client = try zslsk.Client.init(allocator, io);
    defer client.deinit();

    // run application inside zio runtime
    var task = try rt.spawn(app, .{ rt, &client, allocator, io, username, password });
    try task.join(rt);

    print(rt, "[info] shutting down...\n", .{});
}

fn app(rt: *zio.Runtime, client: *zslsk.Client, allocator: std.mem.Allocator, io: std.Io, username: []const u8, password: []const u8) !void {
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

        if (line.len == 0) continue;

        var it = std.mem.splitScalar(u8, line, ' ');
        if (it.next()) |cmd_str| {
            const cmd_or_null = std.meta.stringToEnum(Command, cmd_str);

            if (cmd_or_null) |cmd| {
                switch (cmd) {
                    Command.addlike => {
                        const entry = it.rest();
                        if (entry.len == 0) {
                            print(rt, "[error] syntax: addlike <entry>\n", .{});
                            continue;
                        }

                        client.addLikeInterest(rt, entry) catch |err| {
                            std.log.err("Could not add like interest: {}", .{err});
                            continue;
                        };
                        print(rt, "Like interest added.\n", .{});
                    },
                    Command.rmlike => {
                        const entry = it.rest();
                        if (entry.len == 0) {
                            print(rt, "[error] syntax: rmlike <entry>\n", .{});
                            continue;
                        }

                        client.removeLikeInterest(rt, entry) catch |err| {
                            std.log.err("Could not remove like interest: {}", .{err});
                            continue;
                        };
                        print(rt, "Like interest removed.\n", .{});
                    },
                    Command.addhate => {
                        const entry = it.rest();
                        if (entry.len == 0) {
                            print(rt, "[error] syntax: addhate <entry>\n", .{});
                            continue;
                        }

                        client.addHateInterest(rt, entry) catch |err| {
                            std.log.err("Could not add hate interest: {}", .{err});
                            continue;
                        };
                        print(rt, "Hate interest added.\n", .{});
                    },
                    Command.rmhate => {
                        const entry = it.rest();
                        if (entry.len == 0) {
                            print(rt, "[error] syntax: rmhate <entry>\n", .{});
                            continue;
                        }

                        client.removeHateInterest(rt, entry) catch |err| {
                            std.log.err("Could not remove hate interest: {}", .{err});
                            continue;
                        };
                        print(rt, "Hate interest removed.\n", .{});
                    },
                    Command.download => {
                        const user = it.next() orelse {
                            print(rt, "[error] syntax: download <username> <filename>\n", .{});
                            continue;
                        };

                        const filepath = it.rest();
                        if (filepath.len == 0) {
                            print(rt, "[error] syntax: download <username> <filename>\n", .{});
                            continue;
                        }

                        var dl_channel = client.downloadFile(rt, user, filepath) catch |err| {
                            std.log.err("Could not create download channel: {}", .{err});
                            continue;
                        };
                        defer dl_channel.deinit(rt, allocator);

                        // create/open file for writing
                        const filename = std.fs.path.basenameWindows(filepath);
                        const file = std.Io.Dir.cwd().createFile(io, filename, .{ .truncate = true }) catch |err| {
                            std.log.err("Could not create file: {}", .{err});
                            continue;
                        };

                        // get file writer
                        var write_buf: [4096]u8 = undefined;
                        var writer = file.writer(io, &write_buf);

                        // get terminal size for progress bar
                        const term_width = getTerminalWidth() orelse DEFAULT_TERM_WIDTH;
                        const bar_width = term_width - 12; // padding + borders + pct
                        const progress_step = dl_channel.size / bar_width;

                        // receive bytes from channel until closed
                        var read: u64 = 0;
                        while (read < dl_channel.size) {
                            // attempt to receive a byte
                            const byte = dl_channel.channel.receive(rt) catch |err| {
                                std.log.err("Could not receive from download channel: {}", .{err});
                                break;
                            };

                            read += 1;

                            // flush write_buf when full or done
                            writer.interface.writeByte(byte) catch |err| {
                                std.log.err("Could not write to file: {}", .{err});
                                break;
                            };

                            // print progress bar if there's a bar update
                            if (read % progress_step == 0 or read == dl_channel.size) {
                                const pct = (@as(f64, @floatFromInt(read)) / @as(f64, @floatFromInt(dl_channel.size))) * 100.0;
                                const filled = (read * bar_width) / dl_channel.size;
                                const vacant = bar_width - filled;

                                // carriage return to move cursor to line start
                                print(rt, "\r \u{2590}", .{});
                                for (0..filled) |_| print(rt, "\u{2588}", .{});
                                for (0..vacant) |_| print(rt, "\u{2591}", .{});
                                print(rt, "\u{258C} {d:.1}% ", .{pct});
                            }
                        }
                        writer.interface.flush() catch |err| {
                            std.log.err("Could not flush file writer: {}", .{err});
                            continue;
                        };
                        print(rt, "\n", .{});

                        print(rt, "[info] file downloaded to './{s}'\n", .{filename});
                    },
                    Command.filelist => {
                        const user = it.next() orelse {
                            print(rt, "[error] syntax: filelist <username>\n", .{});
                            continue;
                        };

                        var file_list = client.getSharedFileList(rt, user) catch |err| {
                            std.log.err("Could not get shared file list: {}", .{err});
                            continue;
                        };
                        defer file_list.deinit(allocator);

                        for (file_list.directories) |*dir| {
                            if (dir.files.len > 0) print(rt, "{s}\n", .{dir.name});
                            for (dir.files) |*file| {
                                print(rt, "  {s} ({d} bytes)\n", .{ file.name, file.size });
                            }
                        }
                    },
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
                    Command.setbio => {
                        const bio = it.rest();
                        client.setDescription(bio) catch |err| {
                            std.log.err("Could not set bio: {}", .{err});
                            continue;
                        };
                        print(rt, "Bio set.\n", .{});
                    },
                    Command.setpic => {
                        const path = it.rest();
                        if (path.len == 0) {
                            client.setPicture(null) catch |err| {
                                std.log.err("Could not unset picture: {}", .{err});
                                continue;
                            };
                            print(rt, "Picture unset.\n", .{});
                            continue;
                        }

                        const picture = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
                            print(rt, "[error] could not read file: {}\n", .{err});
                            continue;
                        };
                        defer allocator.free(picture);

                        client.setPicture(picture) catch |err| {
                            std.log.err("Could not set picture: {}", .{err});
                            continue;
                        };
                        print(rt, "Picture set.\n", .{});
                    },
                    Command.search => {
                        const query = it.rest();
                        if (query.len == 0) {
                            print(rt, "[error] syntax: search <query>\n", .{});
                            continue;
                        }

                        const channel = client.fileSearch(rt, query) catch |err| {
                            std.log.err("Could not search network for file: {}", .{err});
                            continue;
                        };

                        _ = try client_group.spawn(rt, printSearchResults, .{ rt, allocator, channel });
                    },
                    Command.share => {
                        const path = it.rest();
                        if (path.len == 0) {
                            print(rt, "[error] syntax: share <abs path>\n", .{});
                            continue;
                        }
                        client.addShare(rt, path) catch |err| {
                            std.log.err("Could not add share: {}", .{err});
                            continue;
                        };
                        print(rt, "Share added.\n", .{});
                    },
                    Command.userinfo => {
                        const user = it.next() orelse {
                            print(rt, "[error] syntax: userinfo <username>\n", .{});
                            continue;
                        };

                        var user_info = client.getUserInfo(rt, user) catch |err| {
                            std.log.err("Likely could not connect to user. error: {}", .{err});
                            continue;
                        };
                        defer user_info.deinit(allocator);

                        var user_interests = client.getUserInterests(rt, user) catch |err| {
                            std.log.err("Likely could not connect to user. error: {}", .{err});
                            continue;
                        };
                        defer user_interests.deinit(allocator);

                        print(rt, "{s}: {s}\n", .{ user, user_info.description });
                        print(rt, "  likes: [ ", .{});
                        for (user_interests.likes) |like| {
                            print(rt, "{s} ", .{like});
                        }
                        print(rt, "]\n", .{});
                        print(rt, "  dislikes: [ ", .{});
                        for (user_interests.dislikes) |dislike| {
                            print(rt, "{s} ", .{dislike});
                        }
                        print(rt, "]\n", .{});
                    },
                    Command.exit => {
                        client.disconnect(rt);
                        break;
                    },
                }
            } else {
                print(rt, "[error] unknown command.\n", .{});
            }
        }
    }
}

/// Prints search results from a channel as they come in.
fn printSearchResults(rt: *zio.Runtime, allocator: std.mem.Allocator, search_channel: zslsk.SearchChannel) void {
    while (search_channel.channel.receive(rt)) |msg| {
        defer msg.deinit(allocator);
        print(rt, "== user {s} | count {d} | speed {B}/s ==\n", .{ msg.username, msg.files.len, msg.avg_speed });
        for (msg.files) |file| {
            print(rt, "\t-> {s} ({d}B)\n", .{ file.name, file.size });
        }
    } else |err| switch (err) {
        error.ChannelClosed => print(rt, "Search complete.\n", .{}),
        else => std.log.err("Failed to receive from channel: {}", .{err}),
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

/// Helper function to get terminal size (POSIX).
fn getTerminalWidth() ?u16 {
    var winsize = std.posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rv = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (rv == 0) {
        if (winsize.row == 0 or winsize.col == 0) {
            return null; // maybe not TTY, invalid result
        }
        return winsize.col;
    }

    // just return null if error, caller should default to some value
    return null;
}
