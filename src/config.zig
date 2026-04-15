const std = @import("std");

pub const Config = struct {
    port:u16 = 9843,
    dir:[]u8 = @constCast("."),
    chroot:bool = true,

    const Valid = enum {
        port,
        dir,
        chroot,
    };

    pub fn init(alloc:std.mem.Allocator) !Config {
        return .{
            .dir = try alloc.dupe(u8, "."),
        };
    }

    pub fn deinit(self:*Config, alloc:std.mem.Allocator) void {
        alloc.free(self.dir);
    }
};

pub fn read(file:*std.fs.File, alloc:std.mem.Allocator) !Config {
    var line_start:usize = 0;

    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    var key:[]u8 = "";

    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);
    var crappy_reader = file.reader(buf);
    const reader = @constCast(&crappy_reader.interface);
    var conf = try Config.init(alloc);

    var i:usize = 0;
    errdefer {
        conf.deinit(alloc);
        crappy_reader.seekTo(line_start) catch |e| @panic(@errorName(e));
        var pos:usize = line_start;
        while (itr(reader, null, null) catch |e| @panic(@errorName(e))) |b| : (pos += 1) {
            if (b == '\n') break;
            if (pos == i)
                std.debug.print("\x0b\x08\x1b[31m^\x1b[A\x1b[31m", .{});
            std.debug.print("{c}\x1b[0m", .{b});
        }
        std.debug.print("\n\n", .{});
    }

    var string:u8 = 0;
    reading: while (try itr(reader, &line_start, &i)) |b| {
        if (string != 0) {
            if (string == b)
                string = 0
            else
                try mem.append(alloc, b);
            continue :reading;
        }
        if (!std.ascii.isWhitespace(b)) switch (b) {
            '"', '\'' => string = b,

            '#' => while (try itr(reader, &line_start, &i)) |c| {
                if (c == '\n') break;
            },

            '=' => key = try mem.toOwnedSlice(alloc),

            else => try mem.append(alloc, b),
        } else if (b == '\n' and mem.items.len > 0) {
            const value = try mem.toOwnedSlice(alloc);
            defer {
                alloc.free(value);
                alloc.free(key);
            }
            const thing = std.meta.stringToEnum(Config.Valid, key) orelse {
                return error.UnknownField;
            };

            switch (thing) {
                .dir => {
                    alloc.free(conf.dir);
                    conf.dir = try alloc.dupe(u8, value);
                },
                .port => {
                    var v:u16 = 0;
                    for (value) |c| {
                        if (!std.ascii.isDigit(c))
                            return error.InvalidNumber;
                        v *= 10;
                        v += c - '0';
                    }
                    conf.port = v;
                },
                .chroot => {
                    conf.chroot =
                        if (std.mem.eql(u8, value, "true"))
                            true
                        else if (std.mem.eql(u8, value, "false"))
                            false
                        else
                            return error.InvalidBoolean;
                },
            }
        }
    }
    return conf;
}

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
