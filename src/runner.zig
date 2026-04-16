const std = @import("std");
const hlp = @import("helpers.zig");
const types = @import("types.zig");

const Request = types.Request;

pub fn exec(in:[]u8, alloc:std.mem.Allocator, req:*Request) ![]u8 {
    const config = req.config;

    const fd_set = try std.posix.pipe();
    {
        var file = std.fs.File{ .handle = fd_set[1] };
        _ = try file.write(
            \\/.bin/busybox --install -s /.bin/
        ++ "\n");
        const n = try file.write(in);
        if (n != in.len) try req.log.err(
            "only wrote {d} bytes of {d}\n", .{n, in.len}
        );
        _ = try file.write(
            \\cd /.bin/
            \\rm $(ls /.bin/ | sed '/^sh$/d' | sed '/^busybox$/d' | sed 's/^/\/\.bin\//g')
        ++ "\n");
    }
    
    const bin_path = b: {
        const reasonable_og_path = try std.fs.cwd().realpathAlloc(alloc, "./.bin");
        const elderly_og_path = try alloc.dupeZ(u8, reasonable_og_path);
        defer {
            alloc.free(reasonable_og_path);
            alloc.free(elderly_og_path);
        }

        const mount_path = try std.fs.path.joinZ(alloc, &[_][]const u8{
            std.fs.path.dirname(reasonable_og_path).?, req.root, ".bin"
        });
        std.fs.cwd().makeDir(mount_path) catch |e|
            if (e != error.PathAlreadyExists) return e;
        const err = std.os.linux.mount(
            elderly_og_path, mount_path, null, std.os.linux.MS.BIND, 0
        );
        if (err != 0) {
            try @constCast(&std.fs.File.stdout().writer(&.{}).interface).print(
                "failed to bind-mount bin dir, cannot proceed without binaries: {s}\n"
            , .{
                switch (std.posix.errno(err)) {
                    .PERM, .ACCES => "permission denied",
                    .NOENT => "no such file or directory",
                    .AGAIN => std.posix.exit(0),
                    else => "",
                }
            });
            return error.@"/bin dir bind mount failed";
        }
        break :b mount_path;
    };
    defer _ = std.os.linux.umount(bin_path);

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

        var envmap = std.process.getEnvMap(alloc) catch |e| {
            std.debug.print("env map: {t}\n", .{e});
            return e;
        };
        envmap.remove("PATH");
        try envmap.put("PATH", "/.bin");

        const err = std.posix.execvpeZ(
            "/.bin/sh", &.{ "/.bin/sh" }, &.{
                "PATH=/.bin",
                null,
            }
        );
        std.debug.print("execvpeZ failed: {t}\n", .{err});
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
