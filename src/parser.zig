const std = @import("std");
const types = @import("types.zig");

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

