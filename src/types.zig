const std = @import("std");

pub const Script = struct {
    txt:[]u8,
    pos:usize,
    end:usize,
    runner:[]u8 = @constCast("bash"), // TODO: possibly more
};

pub const Parsed = struct {
    og:[]u8,
    stripped:[]u8,
    scripts:[]Script
};

pub const Request = struct {
    const Self = @This();
    file:[:0]const u8,
    root:[:0]const u8,
    config:@import("config.zig").Config,
    log:Log,

    const Log = struct {
        stdout:*std.Io.Writer,
        
        pub fn info(self:*Log, comptime msg:[]const u8, fmt:anytype) !void {
            try self.stdout.print("request/info: " ++ msg, fmt);
            try self.stdout.flush();
        }
        pub fn err(self:*Log, comptime msg:[]const u8, fmt:anytype) !void {
            try self.stdout.print("request/error: " ++ msg, fmt);
            try self.stdout.flush();
        }
        pub fn fatal(self:*Log, comptime msg:[]const u8, fmt:anytype) !void {
            try self.stdout.print("request/fatal: " ++ msg, fmt);
            try self.stdout.flush();
        }
    };
};
