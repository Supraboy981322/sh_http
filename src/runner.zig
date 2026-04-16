const std = @import("std");
const hlp = @import("helpers.zig");
const types = @import("types.zig");

const Request = types.Request;

pub fn parse(in:[]u8, alloc:std.mem.Allocator) !types.Parsed{
    var stripped = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = stripped.deinit(alloc);

    var res = types.Parsed{
        .og = in,
        .stripped = undefined,
        .scripts = try alloc.alloc(types.Script, 0),
    };

    var i:usize = 0;
    loop: while (i < in.len) : (i += 1) {
        const b = in[i];
        const do = if (b == '<' and in.len > i+1) in[i+1] == '$' else false;
        if (do) {
            defer i += 1;
            var script = types.Script {
                .txt = undefined,
                .pos = i,
                .end = undefined,
            };
            i += 2;
            inner: while (i < in.len) : (i += 1) {
                if (in[i] == '$' and in.len > i+1) if (in[i+1] == '>') {
                    script.txt = in[script.pos+2..i];
                    script.end = i+2;
                    break :inner;
                };
            }
            var new = try alloc.alloc(types.Script, res.scripts.len+1);
            for (res.scripts, 0..) |s, j| {
                new[j] = s;
            }
            new[new.len - 1] = script;
            alloc.free(res.scripts);
            res.scripts = new;
            continue :loop;
        }
        try stripped.append(alloc, b);
    }
    res.stripped = try stripped.toOwnedSlice(alloc);

    return res;
}

pub fn exec(in:[]u8, alloc:std.mem.Allocator, req:*Request) ![]u8 {
    const config = req.config;

    const fd_set = try std.posix.pipe();
    {
        var file = std.fs.File{ .handle = fd_set[1] };
        const n = try file.write(in);
        if (n != in.len) try req.log.err(
            "only wrote {d} bytes of {d}\n", .{n, in.len}
        );
    }

    const out_pipe = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        defer {
            _ = (std.fs.File{
                .handle = out_pipe[1]
            }).write("[server error]") catch {};
            std.posix.abort();
        }

        try std.posix.dup2(
            std.fs.File.stdout().handle, std.posix.STDERR_FILENO
        );

        if (config.chroot) if (req.root.len > 0) {
            const err = std.os.linux.chroot(req.root);
            if (err != 0) {
                std.debug.print(
                    "exec: failed to chroot, am I running as root? ({s})\n"
                , .{
                    switch (std.posix.errno(err)) {
                        .PERM, .ACCES => "permission denied",
                        .NOENT => "no such file or directory",
                        .AGAIN => std.posix.exit(0),
                        else => "",
                    }
                });
                return error.ChrootFailed;
            }
        };

        try std.posix.chdir("/");

        try std.posix.dup2(
            out_pipe[1], std.posix.STDOUT_FILENO
        );
        try std.posix.dup2(
            fd_set[0], std.posix.STDIN_FILENO
        );

        for ([_]@TypeOf(fd_set[0]){} ++ fd_set ++ out_pipe) |fd| {
            std.posix.close(fd);
        }

        const env = std.process.createEnvironFromMap(
            alloc,
            &(std.process.getEnvMap(alloc) catch |e| {
                std.debug.print("env map: {t}\n", .{e});
                return e;
            }), .{}
        ) catch |e| {
            std.debug.print("env map: {t}\n", .{e});
            return e;
        };

        const err = std.posix.execvpeZ(
            "bash", &.{ "bash", "-" }, env
        );
        try req.log.fatal("execvpeZ failed: {t}\n", .{err});
    }

    for ([_]@TypeOf(fd_set[0]){ out_pipe[1] } ++ fd_set) |fd| {
        std.posix.close(fd);
    }

    defer {
        std.posix.close(out_pipe[0]);
    }

    _ = std.posix.waitpid(pid, 0);

    var buf:[1024]u8 = undefined;
    var output = std.fs.File{ .handle = out_pipe[0] };
    const reader = @constCast(&output.reader(&buf).interface);

    var res = try std.ArrayList(u8).initCapacity(alloc, 1024);
    defer res.deinit(alloc);

    while (try hlp.itr(reader, null, null)) |b| {
        try res.append(alloc, b);
    }

    return res.toOwnedSlice(alloc);
}

pub fn construct(alloc:std.mem.Allocator, parsed:types.Parsed, req:*Request) ![]u8 {
    var res = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer res.deinit(alloc);
    var offset:usize = 0;
    for (parsed.scripts) |script| {
        try res.appendSlice(alloc, parsed.og[offset..script.pos]);
        const out = try exec(script.txt, alloc, req);
        try res.appendSlice(alloc, out);
        if (res.getLastOrNull()) |b| {
            if (b == '\n') _ = res.pop();
        }
        offset = script.end;
    } if (parsed.scripts.len > 1)
        try res.appendSlice(alloc, parsed.og[offset..]);
    return try res.toOwnedSlice(alloc);
}
