const std = @import("std");

pub fn itr(re:*std.Io.Reader, line_start:?*usize, i:?*usize) !?u8 {
    const byte = re.takeByte() catch |e|
        if (e != error.EndOfStream)
            return e
        else
            null;
    if (i) |idx| idx.* += 1;
    if (line_start) |start| if (byte) |b| if (b == '\n') {
        start.* = if (i) |idx| idx.* else unreachable;
    };
    return byte;
}

pub fn write_or_err_and_break(
    file:*std.fs.File,
    msg:[]u8,
    comptime msg_type:[]const u8,
    comptime opts:struct{
        newline:bool = false,
    },
) !bool {
    const n = try file.write(msg);

    var ok = if (n != msg.len) b: {
        std.debug.print(
            msg_type ++ " expected to write {d} bytes, but only wrote {d}\n",
            .{ msg.len, n }
        );
        break :b true;
    } else
        false;

    if (!ok) return false; //write to file or err and break

    if (opts.newline) {
        comptime var new_opts = opts;
        new_opts.newline = false;
        ok = try write_or_err_and_break(file, @constCast("\n"), msg_type, new_opts);
    }

    return ok;
}
