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
