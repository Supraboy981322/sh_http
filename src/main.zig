const std = @import("std");
const conf = @import("config.zig");
const runner = @import("runner.zig");

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
    _ = coms;

    for (0..10) |_| {
        const pid = try std.posix.fork();
        if (pid == 0) {
            while (true) {
                const conn = server.accept() catch |e| {
                    std.debug.print("accept(): {t}\n", .{e});
                    continue;
                };
                try handle_request(conn);// catch |e| {
                //    std.debug.print("handle_request(): {t}\n", .{e});
                //    continue;
                //};
            }
        }
    }
    while(true){}
}

fn handle_request(conn:std.net.Server.Connection) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    defer conn.stream.close();
    
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
        std.debug.print("recieveHead(): {t}\n", .{e});
        return;
    };

    defer request.server.out.flush() catch {};

    var itr = std.mem.splitAny(u8, request.head.target[1..], "?");
    const page =
        if (itr.first().len < 1)
            "/"
        else b: {
            itr.reset();
            break :b itr.first();
        };
    _ = page;

    const src = @embedFile("test.shtm");
    const parsed = try runner.parse(@constCast(src), alloc);
    defer {
        alloc.free(parsed.og);
        alloc.free(parsed.stripped);
    }
    const constructed = try runner.construct(alloc, parsed, config);

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
