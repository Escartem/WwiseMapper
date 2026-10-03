//! UAEPT::lib::utils
//! only the bits wwiseMap uses, rest stayed in the big tool

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = @import("log.zig").scoped(.utils);

pub const Game = enum { hk4e, hkrpg, nap, beyond };

pub const Ctx = struct {
    io: Io,
    alloc: Allocator,
    env: *std.process.Environ.Map,
    prog: std.Progress.Node = .none,
};

// dupe keys -> last one wins like json.loads
pub const json_opts: std.json.ParseOptions = .{ .duplicate_field_behavior = .use_last };

// str.islower(), needs at least one cased char
pub fn pyIsLower(s: []const u8) bool {
    var cased = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) return false;
        if (std.ascii.isLower(c)) cased = true;
    }
    return cased;
}

pub fn removeLowercaseDuplicates(alloc: Allocator, lst: []const []const u8) ![][]const u8 {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    var result: std.ArrayList([]const u8) = .empty;

    for (lst) |s| {
        const key = try std.ascii.allocLowerString(alloc, s);

        const gop = try seen.getOrPut(alloc, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = result.items.len;
            try result.append(alloc, s);
        } else {
            // replace lowercase version if a "normal" one appears
            const idx = gop.value_ptr.*;
            if (pyIsLower(result.items[idx]) and !pyIsLower(s)) {
                result.items[idx] = s;
            }
        }
    }

    return result.items;
}

// parent dir of an output file, so `-o out/x.map` just works
pub fn makeParent(ctx: Ctx, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(ctx.io, d);
}

// json.loads(...) of a list of str, anything else is a skill issue
pub fn jsonStringList(alloc: Allocator, v: std.json.Value) ![][]const u8 {
    if (v != .array) return error.NotAList;
    const out = try alloc.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |e, *o| {
        if (e != .string) return error.NotAString;
        o.* = e.string;
    }
    return out;
}

pub fn readJsonFile(ctx: Ctx, path: []const u8) !std.json.Value {
    const raw = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .unlimited);
    return std.json.parseFromSliceLeaky(std.json.Value, ctx.alloc, raw, json_opts);
}

// json.dumps(list) with python's ", " separator so diffs against v2 outputs stay clean
pub fn writeJsonList(ctx: Ctx, path: []const u8, items: []const []const u8) !void {
    var aw: Io.Writer.Allocating = .init(ctx.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    for (items, 0..) |e, i| {
        if (i != 0) try w.writeAll(", ");
        try std.json.Stringify.value(e, .{}, w);
    }
    try w.writeByte(']');
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = aw.written() });
}

/// "3.10" > "3.9", plain string compare gets that wrong
pub fn versionLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null or pb == null) return pa == null and pb != null;
        const na = std.fmt.parseInt(u64, pa.?, 10) catch 0;
        const nb = std.fmt.parseInt(u64, pb.?, 10) catch 0;
        if (na != nb) return na < nb;
    }
}

// len(str) and not len(bytes), matters for the xor keys
pub fn pyLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

pub fn fmtBytes(buf: []u8, bytes: usize) []const u8 {
    var b: f64 = @floatFromInt(bytes);
    for ([_][]const u8{ "B", "KB", "MB", "GB", "TB" }) |u| {
        if (b < 1024) {
            // f"{b:.2f}" rounds half to even, x/1024 ties are exact so it shows (9.625 -> 9.62)
            const c = b * 100;
            var r = @floor(c);
            const frac = c - r;
            if (frac > 0.5 or (frac == 0.5 and @mod(r, 2) == 1)) r += 1;
            const cents: u64 = @intFromFloat(r);
            return std.fmt.bufPrint(buf, "{d}.{d:0>2}{s}", .{ cents / 100, cents % 100, u }) catch "?";
        }
        b /= 1024;
    }
    return "None"; // lmao
}

// int.to_bytes(n), big endian, raises if it doesn't fit
pub fn putInt(alloc: Allocator, list: *std.ArrayList(u8), value: anytype, n: usize) !void {
    const v: u64 = @intCast(value);
    if (n < 8 and v >> @intCast(n * 8) != 0) return error.OverflowError;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try list.append(alloc, @truncate(v >> @intCast(i * 8)));
    }
}

pub fn xorAppend(alloc: Allocator, list: *std.ArrayList(u8), s: []const u8, key: usize) !void {
    if (key > 255) return error.ValueError; // bytearray([...]) explodes past 255
    for (s) |c| try list.append(alloc, c ^ @as(u8, @intCast(key)));
}

test "versionLess" {
    try std.testing.expect(versionLess("3.9", "3.10"));
    try std.testing.expect(!versionLess("3.10", "3.9"));
    try std.testing.expect(versionLess("4", "4.0"));
    try std.testing.expect(!versionLess("4.0", "4.0"));
}
