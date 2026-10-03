//! UAEPT::lib::mod::wwiseMap::run
//!
//! WWISE MAP MAKER FOR ANIMEWWISE
//! by @Escartem
//!
//! v1 on march 3rd, 2023
//! usage in AnimeWwise on january 7th, 2024 (v2)
//! ported to UAEPT on may 28, 2025 (v2.5)
//! new format on november 25th, 2025 (v3)
//! tsv/csv + lookup database support on february 28th, 2026 (v4)
//! october 2026 public release no wei :O

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const pyrandom = @import("pyrandom.zig");
const Game = utils.Game;
const Bank = @import("db.zig").Bank;
const log = @import("log.zig").scoped(.wwiseMap);

pub const Sector = struct {
    name: []const u8,
    offset: usize,
    size: usize,
};

pub const Options = struct {
    game: Game,
    /// "X.Y", goes in the header
    ver: []const u8,
    /// wem paths, relative to the language folder
    paths: []const []const u8,
    /// music sector, empty = no music
    banks: []const Bank = &.{},
    out: []const u8,
};

pub const Result = struct {
    sectors: [7]Sector,
    total: usize,
    out_file: []const u8,
};

pub const lang_map = std.EnumArray(Game, []const []const u8).init(.{
    .hk4e = &.{ "English(US)", "Japanese", "Chinese", "Korean" },
    .hkrpg = &.{ "Chinese(PRC)", "English", "Japanese", "Korean", "SFX" },
    .nap = &.{ "Chinese(PRC)", "English(EN)", "Japanese(JP)", "Korean(KR)" },
    .beyond = &.{ "English", "Japanese", "Chinese", "Korean" },
});

const KeyVal = struct {
    file: []const u8,
    lang: u8,
};

pub fn fnv(data: []const u8) u64 {
    var hval: u64 = 0xcbf29ce484222325;
    for (data) |byte| {
        hval = hval *% 0x100000001b3;
        hval = hval ^ byte;
    }
    return hval;
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

fn fail(comptime fmt: []const u8, args: anytype) error{RunFailed} {
    log.print(fmt, args);
    return error.RunFailed;
}

pub fn validVersion(ver: []const u8) bool {
    return ver.len >= 3 and std.ascii.isDigit(ver[0]) and ver[1] == '.' and std.ascii.isDigit(ver[2]);
}

pub fn build(ctx: utils.Ctx, opts: Options) !Result {
    const alloc = ctx.alloc;

    if (!validVersion(opts.ver))
        return fail("bad version \"{s}\", need X.Y", .{opts.ver});

    var sz_a: [32]u8 = undefined;
    var sz_b: [32]u8 = undefined;

    // misc data
    const _GAME = opts.game;
    const _GAME_NAME = @tagName(_GAME);
    const _VERSION = opts.ver;

    const langs = lang_map.get(_GAME);

    // steps: load, keys, text, strings, words, files, keys sector, music, write
    const steps = ctx.prog.start("build", 9);
    defer steps.end();

    var paths = opts.paths;
    if (paths.len == 0) return fail("no {s} paths to build from", .{_GAME_NAME});

    // begin now
    {
        var uniq: std.StringArrayHashMapUnmanaged(void) = .empty;
        var old_size: usize = 0;
        for (paths) |e| {
            const stem = e[0 .. std.mem.indexOfScalar(u8, e, '.') orelse e.len]; // remove extension
            if (stem.len == 0) continue; // empty security
            old_size += 1;
            try uniq.put(alloc, stem, {}); // keeps first seen order, set order was random anyway
        }
        const new_size = uniq.count();
        if (old_size != new_size) log.print("> removed {d} extra entries", .{old_size - new_size});
        paths = uniq.keys();

        // same hash anyway, keep one casing and prefer the proper one
        // without it a raw v2 import overflows the strings sector and shows the lowercase eleiyas names
        const merged = try utils.removeLowercaseDuplicates(alloc, paths);
        if (merged.len != paths.len) log.print("> merged {d} case variants", .{paths.len - merged.len});
        paths = merged;
    }
    steps.completeOne();

    var data: std.ArrayList(u8) = .empty;

    // header sector

    var header_sector: std.ArrayList(u8) = .empty;

    // "32" = 12 byte keys, offset(3) | lang(1) | hash(8)
    // "31" = 11 byte keys with the lang packed in the offset's top 2 bits
    try header_sector.appendSlice(alloc, "ESFM\x00\x0032\x00\x00");

    try utils.putInt(alloc, &header_sector, _GAME_NAME.len, 1);
    try header_sector.appendSlice(alloc, _GAME_NAME);
    try utils.putInt(alloc, &header_sector, (_VERSION[0] - '0') * 10 + (_VERSION[2] - '0'), 1);

    // sectors, offset(3) | size(3)
    // post_append_offset = len(header_sector)
    // header_sector += b"\x00" * 36

    // data += header_sector

    // languages sector

    var languages_sector: std.ArrayList(u8) = .empty;
    const languages_sector_offset = data.items.len;

    try utils.putInt(alloc, &languages_sector, langs.len, 1);

    for (langs) |lang| {
        const l = utils.pyLen(lang);
        try utils.putInt(alloc, &languages_sector, l, 1);
        try utils.xorAppend(alloc, &languages_sector, lang, 0x97 + l);
    }

    try data.appendSlice(alloc, languages_sector.items);

    //

    log.print("* computing keys...", .{});

    var keys: std.AutoArrayHashMapUnmanaged(u64, KeyVal) = .empty;
    var neg_keys: usize = 0;
    var full_path: std.ArrayList(u8) = .empty;

    for (langs, 0..) |lang, lang_idx| {
        log.print("- {s}", .{lang});
        const node = steps.start(lang, paths.len);
        defer node.end();
        for (paths, 0..) |e, n| {
            if (n % 4096 == 0) node.setCompletedItems(n);
            full_path.clearRetainingCapacity();

            if (_GAME == .beyond) try full_path.appendSlice(alloc, "voice\\");
            try full_path.appendSlice(alloc, lang);
            try full_path.append(alloc, '\\');

            if (_GAME == .hkrpg) { // star rail weird path fix
                // keep root and filename
                const root = e[0 .. std.mem.indexOfScalar(u8, e, '\\') orelse e.len];
                const filename = e[if (std.mem.lastIndexOfScalar(u8, e, '\\')) |i| i + 1 else 0..];
                const is_sfx = std.mem.eql(u8, lang, "SFX");
                if (std.mem.eql(u8, root, "voice")) {
                    if (is_sfx) continue;
                    try full_path.appendSlice(alloc, root);
                    try full_path.append(alloc, '\\');
                    try full_path.appendSlice(alloc, filename);
                } else {
                    if (!is_sfx) continue;
                    try full_path.appendSlice(alloc, filename); // only filename, usually "sfx/sfx_xxxx.wem"
                }
            } else {
                try full_path.appendSlice(alloc, e); // fake path
            }

            try full_path.appendSlice(alloc, ".wem"); // recreate path
            for (full_path.items) |*c| {
                c.* = std.ascii.toLower(c.*);
                if (_GAME != .hk4e and c.* == '\\') c.* = '/'; // slash fix
            }

            // post encode fix (rjust 16) is free, it's an u64 now
            const key = fnv(full_path.items);

            const gop = try keys.getOrPut(alloc, key);
            if (gop.found_existing) {
                // if (!std.ascii.eqlIgnoreCase(e, gop.value_ptr.file)) {
                //     log.print("skipped {s} -> already in dict ?", .{full_path.items});
                // }
                neg_keys += 1;
            }

            gop.value_ptr.* = .{ .file = e, .lang = @intCast(lang_idx) }; // don't use _e !!
        }
    }

    if (neg_keys != 0) log.print("> {d} keys hit twice", .{neg_keys});
    steps.completeOne();

    // keys lookup

    log.print("* bulding keys lookup table...", .{});
    // keys_lookup[key] is just keys[key].lang now, nothing to build

    // build text data

    log.print("* bulding text data...", .{});

    var strings_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var words_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var old_strings_size: usize = 0;
    var old_words_size: usize = 0;
    var sizes: std.ArrayList(usize) = .empty;
    try sizes.appendNTimes(alloc, 0, 11);
    var max_string: usize = 0;

    // every path, not just the ones that kept a key, so files never misses a word
    for (paths) |path| {
        // words
        // words.extend(list(set(string)))
        var temp: usize = 0;
        var parts_it = std.mem.splitScalar(u8, path, '\\');
        while (parts_it.next()) |part| {
            try words_set.put(alloc, part, {});
            old_words_size += utils.pyLen(part) + 1;

            var n: usize = 0;
            var sub_it = std.mem.splitScalar(u8, part, '_');
            while (sub_it.next()) |sub| {
                n += 1;
                // string = list(set(string))
                try strings_set.put(alloc, sub, {});
                old_strings_size += utils.pyLen(sub) + 1;
            }
            temp = @max(temp, n);
        }

        // max
        if (temp >= sizes.items.len) try sizes.appendNTimes(alloc, 0, temp + 1 - sizes.items.len);
        sizes.items[temp] += 1;
        if (temp > max_string) max_string = temp;
    }

    {
        var aw: Io.Writer.Allocating = .init(alloc);
        try aw.writer.writeByte('{');
        for (sizes.items[1..], 1..) |v, i| {
            if (i > 1) try aw.writer.writeAll(", ");
            try aw.writer.print("{d}: {d}", .{ i, v });
        }
        try aw.writer.writeByte('}');
        log.print("> longest string {d} parts | sizes repartition : {s}", .{ max_string, aw.written() });
    }

    const strings = try alloc.dupe([]const u8, strings_set.keys());
    sortStrings(strings);
    var new_size: usize = strings.len;
    for (strings) |s| new_size += utils.pyLen(s);
    log.print("> optimised data part 1 | {s} -> {s} | (strings)", .{ utils.fmtBytes(&sz_a, old_strings_size), utils.fmtBytes(&sz_b, new_size) });

    const words = try alloc.dupe([]const u8, words_set.keys());
    sortStrings(words);
    new_size = words.len;
    for (words) |s| new_size += utils.pyLen(s);
    log.print("> optimised data part 2 | {s} -> {s} | (words)", .{ utils.fmtBytes(&sz_a, old_words_size), utils.fmtBytes(&sz_b, new_size) });

    steps.completeOne();

    // strings sector

    log.print("* bulding sectors...", .{});
    log.print("> {d} strings", .{strings.len});

    var strings_sector: std.ArrayList(u8) = .empty;
    const strings_sector_offset = data.items.len;
    var strings_offsets: std.StringHashMapUnmanaged(usize) = .empty;

    var rng = pyrandom.Random.init(42);
    rng.shuffle([]const u8, strings);
    for (strings) |string| {
        try strings_offsets.put(alloc, string, strings_sector.items.len);
        var l = utils.pyLen(string);
        const isNumber = string.len > 0 and string[0] != '0' and for (string) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;

        var num: u256 = 0;
        if (isNumber) {
            num = std.fmt.parseInt(u256, string, 10) catch return fail("{s} is a number too big for its own good", .{string});
            const bits = 256 - @clz(num);
            l = (bits + 7) / 8;
            l += 128;
        }

        if (l == 128) {
            log.print("NO NO {s}", .{string});
        }

        if (isNumber) {
            try utils.putInt(alloc, &strings_sector, l, 1);
            var i: usize = l - 128;
            while (i > 0) {
                i -= 1;
                try strings_sector.append(alloc, @truncate(num >> @intCast(i * 8)));
            }
        } else {
            // utf-8 byte length this time, not char count
            utils.putInt(alloc, &strings_sector, string.len, 1) catch return fail("{s} too long ({d})", .{ string, string.len });
            try utils.xorAppend(alloc, &strings_sector, string, (0x97 + string.len) % 255);
        }
    }

    try data.appendSlice(alloc, strings_sector.items);
    // 65 536
    if (strings_sector.items.len > 65535) {
        return fail("a very bad message i cannot keep on github but yeah strings too long vro", .{});
    }

    steps.completeOne();

    // words sector

    log.print("> {d} words", .{words.len});

    var words_sector: std.ArrayList(u8) = .empty;
    const words_sector_offset = data.items.len;
    var words_offsets: std.StringHashMapUnmanaged(usize) = .empty;

    for (words) |word| {
        try words_offsets.put(alloc, word, words_sector.items.len);
        const n_parts = std.mem.countScalar(u8, word, '_') + 1;
        try utils.putInt(alloc, &words_sector, n_parts, 1);

        var it = std.mem.splitScalar(u8, word, '_');
        while (it.next()) |part| {
            const off = strings_offsets.get(part) orelse return fail("KeyError: string {s}", .{part});
            try utils.putInt(alloc, &words_sector, off, 2);
        }
    }

    try data.appendSlice(alloc, words_sector.items);

    steps.completeOne();

    // files sector

    log.print("> {d} files", .{paths.len});

    var files_sector: std.ArrayList(u8) = .empty;
    const files_sector_offset = data.items.len;
    var files_offsets: std.StringHashMapUnmanaged(usize) = .empty;

    for (paths) |file| {
        try files_offsets.put(alloc, file, files_sector.items.len);
        const n_parts = std.mem.countScalar(u8, file, '\\') + 1;

        try utils.putInt(alloc, &files_sector, n_parts, 1);

        var it = std.mem.splitScalar(u8, file, '\\');
        while (it.next()) |part| {
            const off = words_offsets.get(part) orelse return fail("KeyError: word {s} ({s})", .{ part, file });
            try utils.putInt(alloc, &files_sector, off, 3);
        }
    }

    try data.appendSlice(alloc, files_sector.items);

    steps.completeOne();

    // keys sector

    log.print("> {d} keys", .{keys.count()});

    var keys_sector: std.ArrayList(u8) = .empty;
    const keys_sector_offset = data.items.len;

    try utils.putInt(alloc, &keys_sector, 12, 1); // key size

    var kit = keys.iterator();
    while (kit.next()) |entry| {
        const key = entry.key_ptr.*;
        const file = entry.value_ptr.file;
        const lang: usize = entry.value_ptr.lang;

        const offset = files_offsets.get(file) orelse return fail("KeyError: file {s}", .{file});
        utils.putInt(alloc, &keys_sector, offset, 3) catch return fail("file offset 0x{X} doesn't fit in 3 bytes", .{offset});
        try utils.putInt(alloc, &keys_sector, lang, 1); // full index, hkrpg SFX finally gets its own
        try utils.putInt(alloc, &keys_sector, key, 8);
    }

    try data.appendSlice(alloc, keys_sector.items);

    steps.completeOne();

    // music sector

    var music_sector: std.ArrayList(u8) = .empty;
    const music_sector_offset = data.items.len;

    // empty dict is falsy in py, no music sector at all then
    if (opts.banks.len != 0) {
        log.print("> {d} musics", .{opts.banks.len});

        const globalPath = "MusicSegment";
        try utils.putInt(alloc, &music_sector, globalPath.len, 1);
        try music_sector.appendSlice(alloc, globalPath);

        try utils.putInt(alloc, &music_sector, opts.banks.len, 2);

        for (opts.banks) |bank| {
            const l = utils.pyLen(bank.name);
            try utils.putInt(alloc, &music_sector, bank.id, 4);
            try utils.putInt(alloc, &music_sector, l, 1);
            try utils.xorAppend(alloc, &music_sector, bank.name, 0x97 + l);
        }
    }

    try data.appendSlice(alloc, music_sector.items);
    steps.completeOne();

    // end

    var temp: std.ArrayList(u8) = .empty;
    try temp.appendSlice(alloc, header_sector.items);

    log.print("* fixing header offsets", .{});

    var sectors: std.ArrayList(u8) = .empty;
    const table = [_]Sector{
        .{ .name = "header", .offset = 0, .size = header_sector.items.len },
        .{ .name = "languages", .offset = languages_sector_offset, .size = languages_sector.items.len },
        .{ .name = "strings", .offset = strings_sector_offset, .size = strings_sector.items.len },
        .{ .name = "words", .offset = words_sector_offset, .size = words_sector.items.len },
        .{ .name = "files", .offset = files_sector_offset, .size = files_sector.items.len },
        .{ .name = "keys", .offset = keys_sector_offset, .size = keys_sector.items.len },
        .{ .name = "music", .offset = music_sector_offset, .size = music_sector.items.len },
    };
    // languages
    // strings
    // words
    // files
    // keys
    for (table[1..6]) |s| {
        utils.putInt(alloc, &sectors, s.offset, 3) catch return fail("{s} offset 0x{X} doesn't fit in 3 bytes", .{ s.name, s.offset });
        utils.putInt(alloc, &sectors, s.size, 3) catch return fail("{s} size {d} doesn't fit in 3 bytes", .{ s.name, s.size });
    }
    // music
    if (music_sector_offset > 256 * 256 * 256) {
        try sectors.appendSlice(alloc, "\xFF\xFF\xFF");
        try utils.putInt(alloc, &sectors, music_sector_offset, 4);
    } else {
        try utils.putInt(alloc, &sectors, music_sector_offset, 3);
    }
    try utils.putInt(alloc, &sectors, music_sector.items.len, 3);

    // data[post_append_offset:post_append_offset+36] = sectors
    try temp.appendSlice(alloc, sectors.items);
    // sector_start = len(temp)
    // temp += sector_start.to_bytes(1, "big")
    try temp.appendSlice(alloc, data.items);

    // done
    try printTable(alloc, &table);
    log.print("TOTAL : {s}", .{utils.fmtBytes(&sz_a, temp.items.len)});

    const out_file = opts.out;
    log.print(">>> {s} ({d} total bytes)", .{ out_file, temp.items.len });
    try utils.makeParent(ctx, out_file);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out_file, .data = temp.items });
    steps.completeOne();

    return .{ .sectors = table, .total = temp.items.len, .out_file = out_file };
}

// tabulate(table, headers="keys", tablefmt="grid")
fn printTable(alloc: Allocator, table: []const Sector) !void {
    const headers = [3][]const u8{ "sector", "offset", "size" };
    var cells: std.ArrayList([3][]const u8) = .empty;
    for (table) |s| {
        var sz: [32]u8 = undefined;
        try cells.append(alloc, .{
            s.name,
            try std.fmt.allocPrint(alloc, "0x{X}", .{s.offset}),
            try alloc.dupe(u8, utils.fmtBytes(&sz, s.size)),
        });
    }

    var w: [3]usize = undefined;
    for (&w, headers) |*x, h| x.* = h.len + 2; // tabulate MIN_PADDING
    for (cells.items) |row| for (&w, row) |*x, c| {
        x.* = @max(x.*, c.len);
    };

    var aw: Io.Writer.Allocating = .init(alloc);
    const out = &aw.writer;

    const sep = struct {
        fn line(o: *Io.Writer, widths: [3]usize, ch: u8) !void {
            try o.writeByte('+');
            for (widths) |x| {
                try o.splatByteAll(ch, x + 2);
                try o.writeByte('+');
            }
        }
        fn row(o: *Io.Writer, widths: [3]usize, r: [3][]const u8) !void {
            try o.writeByte('|');
            for (widths, r) |x, c| {
                try o.print(" {s}", .{c});
                try o.splatByteAll(' ', x - c.len + 1);
                try o.writeByte('|');
            }
        }
    };

    try sep.line(out, w, '-');
    log.print("{s}", .{aw.written()});
    aw.clearRetainingCapacity();
    try sep.row(out, w, headers);
    log.print("{s}", .{aw.written()});
    aw.clearRetainingCapacity();
    try sep.line(out, w, '=');
    log.print("{s}", .{aw.written()});
    for (cells.items) |r| {
        aw.clearRetainingCapacity();
        try sep.row(out, w, r);
        log.print("{s}", .{aw.written()});
        aw.clearRetainingCapacity();
        try sep.line(out, w, '-');
        log.print("{s}", .{aw.written()});
    }
}

test "i ponder" {
    // fnv(b"english(us)\\vo_aq\\vo_paimon\\vo_xmaq004_2_paimon_01.wem") from wwiseMap_2.py
    try std.testing.expectEqual(@as(u64, 0x94043ecf66cd4982), fnv("english(us)\\vo_aq\\vo_paimon\\vo_xmaq004_2_paimon_01.wem"));
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv(""));
}
