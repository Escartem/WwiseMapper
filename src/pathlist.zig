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

    // Only known audio suffixes are extensions; other dots belong to the name.
    const name = rest[rest.len - 1];
    var stem = name;
    for ([_][]const u8{ ".wem", ".wav", ".ogg", ".mp3", ".flac", ".opus" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) {
            stem = name[0 .. name.len - ext.len];
            break;
        }
    }
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

test "text imports preserve dots in directory and file names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try parse(
        a,
        .hkrpg,
        "hash\tpath\r\n" ++
            "23ee2e30638cb6b7\tChinese(PRC)/voice/chapter4/64.5/danfeng/chapter4_64.5_danfeng_101.wem\r\n" ++
            "a252fa3a0496e359\tvoice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_101.ogg\r\n" ++
            "voice/chapter4/64/hysilens/chapter4_64_hysilens_113_m\n",
    );
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("voice\\chapter4\\64.5\\danfeng\\chapter4_64.5_danfeng_101.wem", paths[0]);
    try std.testing.expectEqualStrings("voice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_101.wem", paths[1]);
    try std.testing.expectEqualStrings("voice\\chapter4\\64\\hysilens\\chapter4_64_hysilens_113_m.wem", paths[2]);
}

test "text imports preserve extensionless decimal names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try parse(
        arena.allocator(),
        .hkrpg,
        "23ee2e30638cb6b7\tvoice\\chapter4\\64.5\\danfeng\\chapter4_64.5_danfeng_101\n" ++
            "3574cc313b2dc6f6\tvoice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_102\n" ++
            "8b1fae27bc5b6c5f\tvoice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_103\n" ++
            "a252fa3a0496e359\tvoice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_101\n",
    );
    const expected = [_][]const u8{
        "voice\\chapter4\\64.5\\danfeng\\chapter4_64.5_danfeng_101.wem",
        "voice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_102.wem",
        "voice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_103.wem",
        "voice\\chapter4\\64.5\\danheng\\chapter4_64.5_danheng_101.wem",
    };
    try std.testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "normalize replaces known audio extensions and preserves other suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "voice\\chapter4\\64.5\\danfeng\\chapter4_64.5_danfeng_101";
    for ([_][]const u8{ ".wem", ".WEM", ".wav", ".ogg", ".OGG", ".mp3", ".flac", ".opus" }) |ext| {
        const input = try std.fmt.allocPrint(a, "{s}{s}", .{ base, ext });
        try std.testing.expectEqualStrings(base ++ ".wem", (try normalize(a, .hkrpg, input)).?);
    }
    try std.testing.expectEqualStrings(base ++ ".custom.wem", (try normalize(a, .hkrpg, base ++ ".custom")).?);
    try std.testing.expectEqualStrings("voice\\chapter4_64.5.wem", (try normalize(a, .hkrpg, "voice/chapter4_64.5")).?);
}
