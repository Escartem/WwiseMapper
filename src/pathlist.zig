const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Game = utils.Game;
const map = @import("map.zig");
const log = @import("log.zig").scoped(.pathlist);

pub fn isText(file: []const u8) bool {
    const ext = std.fs.path.extension(file);
    return std.ascii.eqlIgnoreCase(ext, ".txt") or std.ascii.eqlIgnoreCase(ext, ".tsv");
}

pub fn read(ctx: utils.Ctx, game: Game, file: []const u8) ![][]const u8 {
    const raw = try Io.Dir.cwd().readFileAlloc(ctx.io, file, ctx.alloc, .unlimited);
    return parse(ctx.alloc, game, raw);
}

fn parse(alloc: Allocator, game: Game, raw: []const u8) ![][]const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (lines.next()) |line_raw| {
        defer first = false;
        var line = std.mem.trim(u8, line_raw, " \t\r\u{feff}");
        if (line.len == 0) continue;
        // tsv, the path is whatever comes after the hash
        if (std.mem.lastIndexOfScalar(u8, line, '\t')) |i| line = std.mem.trim(u8, line[i + 1 ..], " ");
        // header row
        if (first and std.ascii.eqlIgnoreCase(line, "path")) continue;
        const p = try normalize(alloc, game, line) orelse continue;
        try seen.put(alloc, p, {});
    }
    return seen.keys();
}

/// `English(US)/VO_AQ/x` -> `VO_AQ\x.wem`
pub fn normalize(alloc: Allocator, game: Game, path: []const u8) !?[]const u8 {
    const langs = map.lang_map.get(game);

    // split on both slash kinds, empty parts (`//`, leading `/`, `./`) go away
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        try parts.append(alloc, part);
    }
    if (parts.items.len == 0) return null;

    // language folder and anything before it (beyond's `voice\`, dump roots...), never the filename itself
    var start: usize = 0;
    outer: for (parts.items[0 .. parts.items.len - 1], 0..) |part, i| {
        for (langs) |lang| if (std.ascii.eqlIgnoreCase(part, lang)) {
            start = i + 1;
            break :outer;
        };
    }
    const rest = parts.items[start..];

    // whatever extension it had becomes .wem, same as build's first `.` cut
    const name = rest[rest.len - 1];
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    if (stem.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    for (rest[0 .. rest.len - 1]) |part| {
        try out.appendSlice(alloc, part);
        try out.append(alloc, '\\');
    }
    try out.appendSlice(alloc, stem);
    try out.appendSlice(alloc, ".wem");
    return out.items;
}

test normalize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = std.testing.expectEqualStrings;

    try eq("VO_AQ\\VO_paimon\\vo_x.wem", (try normalize(a, .hk4e, "English(US)/VO_AQ/VO_paimon/vo_x.wem")).?);
    try eq("VO_AQ\\vo_x.wem", (try normalize(a, .hk4e, "english(us)\\VO_AQ\\vo_x")).?);
    try eq("VO_AQ\\vo_x.wem", (try normalize(a, .hk4e, "VO_AQ//vo_x.ogg")).?);
    try eq("dlg\\x.wem", (try normalize(a, .beyond, "voice/English/dlg/x.wem")).?);
    try eq("voice\\x.wem", (try normalize(a, .hkrpg, "Japanese/voice/x.wem")).?);
    try eq("sfx\\sfx_1.wem", (try normalize(a, .hkrpg, "SFX/sfx/sfx_1.wem")).?);
    try eq("Ex\\x.wem", (try normalize(a, .nap, "Korean(KR)/Ex/x")).?);
    // a lone filename named like a language stays
    try eq("English.wem", (try normalize(a, .beyond, "English")).?);
    try std.testing.expect(try normalize(a, .hk4e, "/") == null);
}

test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), .hk4e, "hash\tpath\r\n123\tEnglish(US)\\VO_AQ\\a.wem\r\n\n456\tJapanese/VO_AQ/a\r\nVO_AQ/b\n");
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("VO_AQ\\a.wem", got[0]);
    try std.testing.expectEqualStrings("VO_AQ\\b.wem", got[1]);
}
