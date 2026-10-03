//! UAEPT::lib::mod::wwiseMap::AudioParser
//! raw game data (from fetch) -> flat list of wem paths, the generic input for build

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Game = utils.Game;
const log = @import("log.zig").scoped(.AudioParser);

pub const AudioParser = struct {
    ctx: utils.Ctx,
    in: []const u8,
    out: []const u8,

    /// reads what fetch dropped in `in`, writes the paths list to `out`
    pub fn parse(ctx: utils.Ctx, game: Game, in: []const u8, out: []const u8) ![][]const u8 {
        var self: AudioParser = .{ .ctx = ctx, .in = in, .out = out };
        const names = switch (game) {
            .hk4e => try self.hk4e(),
            .hkrpg => try self.hkrpg(),
            .nap => try self.nap(),
            .beyond => try self.beyond(),
        };
        try self.dump(names);
        return names;
    }

    fn inPath(self: *AudioParser, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.ctx.alloc, &.{ self.in, name });
    }

    fn readIn(self: *AudioParser, name: []const u8) !std.json.Value {
        const path = try self.inPath(name);
        return utils.readJsonFile(self.ctx, path) catch |err| {
            log.print("can't read {s} ({t}), did you run fetch ?", .{ path, err });
            return err;
        };
    }

    fn dump(self: *AudioParser, names: []const []const u8) !void {
        try utils.makeParent(self.ctx, self.out);
        try utils.writeJsonList(self.ctx, self.out, names);
        log.print("> {d} names -> {s}", .{ names.len, self.out });
    }

    // gi audio parser
    // /BinOutput/Voice/*.json
    // /BinOutput/Voice/Items/*.json
    // covers only voicelines
    //
    // https://gitlab.com/Dimbreath/AnimeGameData/-/tree/master/BinOutput/Voice/Items
    fn hk4e(self: *AudioParser) ![][]const u8 {
        const io = self.ctx.io;
        const alloc = self.ctx.alloc;

        log.print("/!\\ Genshin detected, this could kill your I/O", .{});

        var all_sources: std.ArrayList([]const u8) = .empty;
        var skips: std.ArrayList([]const u8) = .empty;

        const items_path = try self.inPath("items");
        var dir = Io.Dir.cwd().openDir(io, items_path, .{ .iterate = true }) catch |err| {
            log.print("can't open {s} ({t}), did you run fetch ?", .{ items_path, err });
            return err;
        };
        defer dir.close(io);

        // count first so the bar has a denominator
        var total: usize = 0;
        {
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .file) total += 1;
            }
        }
        const node = self.ctx.prog.start("voice items", total);
        defer node.end();

        var it = dir.iterate();
        var n_files: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const file = try alloc.dupe(u8, entry.name);
            n_files += 1;
            defer node.completeOne();

            // whole file stays in the arena on purpose, names point into it
            const raw = try dir.readFileAlloc(io, file, alloc, .unlimited);
            const data = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, utils.json_opts) catch {
                const text = try std.fmt.allocPrint(alloc, "skipped value in {s} at <root>", .{file});
                try skips.append(alloc, text);
                continue;
            };

            // `for in_file in data` on a list -> data[dict] -> TypeError, so everything gets skipped
            if (data != .object) {
                if (data == .array) for (data.array.items) |_| {
                    const text = try std.fmt.allocPrint(alloc, "skipped value in {s} at <list item>", .{file});
                    try skips.append(alloc, text);
                };
                continue;
            }

            var obj_it = data.object.iterator();
            while (obj_it.next()) |kv| {
                const in_file = kv.key_ptr.*;
                hk4eEntry(alloc, kv.value_ptr.*, &all_sources) catch {
                    const text = try std.fmt.allocPrint(alloc, "skipped value in {s} at {s}", .{ file, in_file });
                    try skips.append(alloc, text);
                };
            }
        }

        log.print("> {d} files, {d} sources, {d} skips", .{ n_files, all_sources.items.len, skips.items.len });

        // too spammy for the console, goes next to the output instead
        if (skips.items.len != 0) {
            var aw: Io.Writer.Allocating = .init(alloc);
            for (skips.items) |e| {
                try aw.writer.writeAll(e);
                try aw.writer.writeByte('\n');
            }
            const log_path = try std.fmt.allocPrint(alloc, "{s}.skipped.txt", .{self.out});
            try utils.makeParent(self.ctx, log_path);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = aw.written() });
            log.print("> skips -> {s}", .{log_path});
        }

        return all_sources.items;
    }

    fn hk4eEntry(alloc: Allocator, v: std.json.Value, out: *std.ArrayList([]const u8)) !void {
        switch (v) {
            .object => |o| {
                if (o.get("SourceNames")) |names| {
                    for ((try asArray(names)).items) |name| try out.append(alloc, try strField(name, "sourceFileName"));
                }

                // 4.4 patch
                if (o.get("EIKJKDICKMJ")) |names| {
                    for ((try asArray(names)).items) |name| try out.append(alloc, try strField(name, "HLGOMILNFNK"));
                }

                // 4.6 patch (i know it's just one letter diff from first one but stfu)
                if (o.get("sourceNames")) |names| {
                    for ((try asArray(names)).items) |name| try out.append(alloc, try strField(name, "sourceFileName"));
                }
            },
            .string, .array => {},
            else => return error.TypeError,
        }
    }

    fn asArray(v: std.json.Value) !std.json.Array {
        return if (v == .array) v.array else error.TypeError;
    }

    fn strField(v: std.json.Value, key: []const u8) ![]const u8 {
        if (v != .object) return error.TypeError;
        const f = v.object.get(key) orelse return error.KeyError;
        return if (f == .string) f.string else error.TypeError;
    }

    fn posfix(s: []const u8) usize {
        return if (std.mem.endsWith(u8, s, "_f") or std.mem.endsWith(u8, s, "_m")) 2 else 1;
    }

    // "\\".join(s.split("_")[:posfix(s)])
    fn betterPath(alloc: Allocator, s: []const u8) ![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, s, '_');
        while (it.next()) |p| try parts.append(alloc, p);
        const drop = posfix(s);
        const keep = if (parts.items.len > drop) parts.items.len - drop else 0;
        return std.mem.join(alloc, "\\", parts.items[0..keep]);
    }

    // hsr audio parser
    // /ExcelOutput/VoiceConfig.json
    // list, for each
    // lang/voice/e[VoicePath].wem + my own funny path
    // covers only voicelines
    //
    // https://gitlab.com/Dimbreath/turnbasedgamedata/-/blob/main/ExcelOutput/VoiceConfig.json
    fn hkrpg(self: *AudioParser) ![][]const u8 {
        const alloc = self.ctx.alloc;

        var names: std.StringArrayHashMapUnmanaged(void) = .empty;

        // og re-reads the 3 files for each suffix, once is enough
        const sources = [_]struct { file: []const u8, field: []const u8, voice: bool }{
            .{ .file = "VoiceConfig.json", .field = "VoicePath", .voice = true },
            .{ .file = "ResourceDeletionVPList.json", .field = "Path", .voice = true },
            .{ .file = "SFXConfig.json", .field = "SFXPath", .voice = false },
        };

        var datas: [sources.len]std.json.Value = undefined;
        for (sources, &datas) |src, *d| {
            d.* = try self.readIn(src.file);
            if (d.* != .array) return error.TypeError;
            log.print("> {s} : {d} entries", .{ src.file, d.array.items.len });
        }

        for ([_][]const u8{ "", "_f", "_m" }) |suffix| {
            for (sources, datas) |src, data| {
                for (data.array.items) |e| {
                    const p = strField(e, src.field) catch {
                        log.print("skipped entry without {s} in {s}", .{ src.field, src.file });
                        continue;
                    };
                    const bp = try betterPath(alloc, p); // not official but for the sake of readability
                    const name = if (src.voice)
                        try std.fmt.allocPrint(alloc, "voice\\{s}\\{s}{s}.wem", .{ bp, p, suffix })
                    else
                        try std.fmt.allocPrint(alloc, "{s}\\{s}{s}.wem", .{ bp, p, suffix });
                    try names.put(alloc, name, {});
                }
            }
        }

        return names.keys();
    }

    // https://git.mero.moe/dimbreath/ZenlessData
    //
    // zzz audio parser
    // /Data/AudioResourceData.json
    // dict[externals].keys
    // -> lang/Ex/key[prefix]/key.wem
    // only voicelines ?
    //
    // https://git.mero.moe/dimbreath/ZenlessData/src/branch/master/Data/AudioResourceData.json
    // 1.7+ -> https://git.mero.moe/dimbreath/ZenlessData/src/branch/master/Data/JsonBytes/Audio/AudioResourceData.json
    // 2.3+ : broken fuck
    fn nap(self: *AudioParser) ![][]const u8 {
        const alloc = self.ctx.alloc;
        var names: std.ArrayList([]const u8) = .empty;

        const root = try self.readIn("AudioResourceData.json");
        if (root != .object) return error.TypeError;
        const data = root.object.get("externals") orelse {
            log.print("no \"externals\" in AudioResourceData.json, 2.3+ format, use --dbMode", .{});
            return error.KeyError;
        };
        if (data != .object) return error.TypeError;

        var it = data.object.iterator();
        while (it.next()) |kv| {
            const e = kv.key_ptr.*;
            const prefix = try std.mem.replaceOwned(u8, alloc, try strField(kv.value_ptr.*, "prefix"), "/", "\\");
            const path = try std.fmt.allocPrint(alloc, "Ex\\{s}{s}.wem", .{ prefix, e });
            try names.append(alloc, path);
        }

        return names.items;
    }

    // https://github.com/Dimbreath/EndfieldData
    //
    // akef audio parser
    // /TableCfg/AudioDialog.json
    // dict.hash
    // -> voice/lang/hash[path]
    // covers only voicelines
    //
    // https://github.com/Dimbreath/EndfieldData/blob/master/TableCfg/AudioDialog.json
    fn beyond(self: *AudioParser) ![][]const u8 {
        const alloc = self.ctx.alloc;
        var names: std.ArrayList([]const u8) = .empty;

        const data = try self.readIn("AudioDialog.json");
        if (data != .object) return error.TypeError;

        for (data.object.values()) |e| {
            const path = try std.mem.replaceOwned(u8, alloc, try strField(e, "path"), "/", "\\");
            try names.append(alloc, path);
        }

        return names.items;
    }
};
