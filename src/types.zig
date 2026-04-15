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
