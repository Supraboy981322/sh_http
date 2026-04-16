const std = @import("std");
const conf = @import("config.zig");
const runner = @import("runner.zig");
const hlp = @import("helpers.zig");
const types = @import("types.zig");

const Config = conf.Config;

var config:Config = .{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var config_file = std.fs.cwd().openFile("config", .{ .mode = .read_only }) catch |e| b: {
        if (e != error.FileNotFound) {
            var stderr = @constCast(&std.fs.File.stderr()).writer(&.{}).interface;
            try stderr.print("failed to read config: {t}\n", .{e});
            std.process.abort();
        }
        const txt =
            \\# this is the default sh_http config
            \\dir = "."
            \\port = 4380
            \\chroot = true
        ;
        var file = try std.fs.cwd().createFile("config", .{ .read = true });
        const n = try file.write(txt);
        if (n != txt.len) std.debug.panic(
            "error writing default config:"
                ++ "expected to write {d} bytes,"
                ++ "but only wrote {d}\n"
        , .{txt.len, n});

        break :b file;
    };

    defer config_file.close();
    config = try @import("config.zig").read(&config_file, alloc);
    defer config.deinit(alloc);

    const addr = try std.net.Address.resolveIp("::", config.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("listening on port {d}\n", .{config.port});
    
    const coms = try std.posix.pipe();

    var pids = try alloc.alloc(std.posix.pid_t, config.conn_forks);
    defer alloc.free(pids);

    var stop:bool = false;
    _ = &stop;

    for (0..config.conn_forks) |i| {
        const pid = try std.posix.fork();
        if (pid == 0) {
            try std.posix.dup2(
                coms[1], std.posix.STDOUT_FILENO
            );
            var buf:[1024]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&buf).interface;
            while (true) {
                const conn = server.accept() catch |e| {
                    try stdout.print("error accepting request: {t}\n", .{e});
                    continue;
                };
                defer conn.stream.close();
                handle_request(conn, &stdout) catch |e| {
                    try stdout.print("error accepting request: {t}\n", .{e});
                    continue;
                };
            }
        }
        pids[i] = pid;
    }

    std.debug.print("spawned {d} listeners\n", .{config.conn_forks});

    var msgs = try std.ArrayList([]u8).initCapacity(alloc, 0);
    defer {
        for (msgs.items) |msg|
            alloc.free(msg);
        msgs.deinit(alloc);
    }
    const whitespace = comptime b: {
        const space = std.ascii.whitespace;
        var arr = [_]u8{0} ** space.len;
        for (space, 0..) |s, i|
            arr[i] = s;
        break :b arr;
    };
    loop: while(!stop){
        var buf:[1024]u8 = undefined;
        const n = try std.posix.read(coms[0], &buf);
        if (n > 0) {
            const message = std.mem.trim(u8, buf[0..n], &whitespace);
            var just_created_log:bool = false;

            var file = @constCast(&(
                std.fs.cwd().openFile(
                    "sh_http.log", .{ .mode = .write_only }
                ) catch |e| if (e != error.FileNotFound) {
                    std.debug.print("failed to access log file: {t}\n", .{e});
                    break :loop;
                } else b: {
                    just_created_log = true;
                    break :b try std.fs.cwd().createFile("sh_http.log", .{});
                }
            ));
            _ = &file;

            if (just_created_log) for (msgs.items) |msg| {
                if (try hlp.write_or_err_and_break(
                    file, msg, "log", .{ .newline = true }
                )) break :loop;
            };

            if (try hlp.write_or_err_and_break(
                file, @constCast(message), "log", .{ .newline = true }
            )) break :loop;

            try msgs.append(alloc, try alloc.dupe(u8, message));
            std.debug.print("{s}\n", .{message});
        }
    }
    for (pids) |pid|
        try std.posix.kill(pid, 9);
}

fn handle_request(conn:std.net.Server.Connection, stdout:*std.Io.Writer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var reader = b: {
        var buf:[1024]u8 = undefined;
        break :b conn.stream.reader(&buf);
    };

    var writer = b: {
        var buf:[1024]u8 = undefined;
        break :b conn.stream.writer(&buf);
    };

    var server = std.http.Server.init(reader.interface(), &writer.interface);

    var request = server.receiveHead() catch |e| {
        try stdout.print("recieveHead(): {t}\n", .{e});
        return;
    };

    defer request.server.out.flush() catch {};

    var page:[]const u8 = undefined;
    {
        var itr = std.mem.splitAny(u8, request.head.target[1..], "?");
        page =
            if (itr.first().len < 1)
                "/"
            else b: {
                itr.reset();
                break :b itr.first();
            };
    }

    const src = @embedFile("test.shtm");
    const parsed = try runner.parse(@constCast(src), alloc);
    defer {
        alloc.free(parsed.og);
        alloc.free(parsed.stripped);
    }
    const constructed = try runner.construct(alloc, parsed, @constCast(&types.Request{
        .config = config,
        .log = .{ .stdout = stdout },
        .file = b: {
            var page_itr = std.mem.splitBackwardsAny(u8, page, "/");
            break :b @constCast(page_itr.first());
        },
        .root = b: {
            var page_itr = std.mem.splitAny(u8, page, "/");
            break :b @constCast(page_itr.first());
        },
    }));

    for ([_][]const u8{
        "HTTP/1.1 200 OK",
        "",
    }) |header| {
        request.server.out.print("{s}\r\n", .{header}) catch {};
        request.server.out.flush() catch {};
    }

    request.server.out.print("{s}", .{constructed}) catch {};
    request.server.out.flush() catch {};
}
