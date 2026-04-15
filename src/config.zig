const std = @import("std");
const hlp = @import("helpers.zig");

const itr = hlp.itr;

pub const Config = struct {
    port:u16 = 9843,
    dir:[]u8 = @constCast("."),
    chroot:bool = true,
    conn_forks:u64 = 10,
    max_forks:u64 = std.math.maxInt(u64),

    const Valid = enum {
        port,
        dir,
        chroot,
        @"connection listeners",
        @"max forks",
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
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    var key:[]u8 = try alloc.alloc(u8, 0);
    defer alloc.free(key);

    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);
    var crappy_reader = file.reader(buf);
    const reader = @constCast(&crappy_reader.interface);
    var conf = try Config.init(alloc);

    var i:usize = 0;
    var line_no:usize = 0;
    errdefer {
        conf.deinit(alloc);
        crappy_reader.seekTo(0) catch |e| @panic(@errorName(e));
        var line_start:usize = 0;
        {
            var j:usize = 0;
            while (itr(reader, &j, &line_start) catch |e| @panic(@errorName(e))) |_| {
                if (j == line_no-1) break;
            }
        }
        var pos:usize = i;
        while (itr(reader, null, null) catch |e| @panic(@errorName(e))) |b| : (pos += 1) {
            if (b == '\n') break;
            std.debug.print("\x1b[3{d}m{c}\x0b\x08\x1b[35m^\x1b[A\x1b[0m",
            .{
                @as(u3, if (std.ascii.isDigit(b))
                    3
                else if (std.ascii.isAlphabetic(b))
                    4
                else
                    6
                ),
                b
            });
        }
        std.debug.print("\n\n", .{});
    }

    var string:u8 = 0;
    reading: while (try itr(reader, &line_no, &i)) |b| {
        if (string != 0) {
            if (string == b)
                string = 0
            else
                try mem.append(alloc, b);
            continue :reading;
        }
        if (!std.ascii.isWhitespace(b)) switch (b) {
            '"', '\'' => string = b,

            '#' => while (try itr(reader, &line_no, &i)) |c| {
                if (c == '\n') break;
            },

            '=' => {
                alloc.free(key);
                key = try mem.toOwnedSlice(alloc);
            },

            else => try mem.append(alloc, b),
        } else if (b == '\n' and mem.items.len > 0) {
            const value = try mem.toOwnedSlice(alloc);
            defer alloc.free(value);
            if (key.len < 1)
                return error.UnexpectedNewline;
            const thing = std.meta.stringToEnum(Config.Valid, key) orelse {
                alloc.free(key);
                key = try alloc.alloc(u8, 0);
                return error.UnknownField;
            };

            alloc.free(key);
            key = try alloc.alloc(u8, 0);

            switch (thing) {
                .dir => {
                    alloc.free(conf.dir);
                    conf.dir = try alloc.dupe(u8, value);
                },
                .port => conf.port = try hlp.to_int_or_err(value, u16),
                .chroot => {
                    conf.chroot =
                        if (std.mem.eql(u8, value, "true"))
                            true
                        else if (std.mem.eql(u8, value, "false"))
                            false
                        else
                            return error.InvalidBoolean;
                },
                .@"connection listeners", .@"max forks" => {
                    const field = &switch (thing) {
                        .@"connection listeners" => conf.conn_forks,
                        .@"max forks" => conf.max_forks,
                        else => unreachable,
                    };
                    field.* = try hlp.to_int_or_err(value, u64);
                },
            }
        }
    }
    return conf;
}
