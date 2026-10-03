//! UAEPT::lib::mod::wwiseMap::main
//!
//! wwisemap fetch  -g <game> [-o dir]
//! wwisemap parse  -g <game> [-i dir] [-o paths.json]
//! wwisemap append -g <game> -v X.Y [-p paths.json|.txt|.tsv] [-b banks.json] [-d v1|v2] [--data dir]
//! wwisemap build  -g <game> -v X.Y [-d v1|v2] [-o out.map] [--data dir]
//! wwisemap update -g <game> -v X.Y [-p paths.txt|.tsv] [-b banks.json] [--data dir]

const std = @import("std");
const utils = @import("utils.zig");
const Game = utils.Game;
const map = @import("map.zig");
const dbm = @import("db.zig");
const AudioFetch = @import("fetch.zig").AudioFetch;
const AudioParser = @import("parser.zig").AudioParser;
const pathlist = @import("pathlist.zig");
const logm = @import("log.zig");
const log = logm.scoped(.db);

const Command = enum { fetch, parse, append, build, update, help };

const Args = struct {
    game: ?Game = null,
    ver: ?[]const u8 = null,
    in: ?[]const u8 = null,
    out: ?[]const u8 = null,
    paths: ?[]const u8 = null,
    bank: ?[]const u8 = null,
    db: ?dbm.Kind = null,
    data: []const u8 = "data",
};

const Opt = enum { game, ver, in, out, paths, bank, db, data };

const opt_names = [_]struct { opt: Opt, long: []const u8, short: ?[]const u8 = null }{
    .{ .opt = .game, .long = "--game", .short = "-g" },
    .{ .opt = .ver, .long = "--ver", .short = "-v" },
    .{ .opt = .in, .long = "--in", .short = "-i" },
    .{ .opt = .out, .long = "--out", .short = "-o" },
    .{ .opt = .paths, .long = "--paths", .short = "-p" },
    .{ .opt = .bank, .long = "--bank", .short = "-b" },
    .{ .opt = .db, .long = "--db", .short = "-d" },
    .{ .opt = .data, .long = "--data" },
};

fn lookup(a: []const u8) ?Opt {
    for (opt_names) |o| {
        if (std.mem.eql(u8, a, o.long)) return o.opt;
        if (o.short) |s| if (std.mem.eql(u8, a, s)) return o.opt;
    }
    return null;
}

fn parseArgs(args: []const [:0]const u8) !Args {
    var r: Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = lookup(args[i]) orelse {
            std.debug.print("unknown option {s}\n", .{args[i]});
            return error.Usage;
        };
        i += 1;
        if (i >= args.len) {
            std.debug.print("{s} needs a value\n", .{args[i - 1]});
            return error.Usage;
        }
        const v: []const u8 = args[i];
        switch (opt) {
            .game => r.game = std.meta.stringToEnum(Game, v) orelse {
                std.debug.print("unknown game {s}\n", .{v});
                return error.Usage;
            },
            .db => r.db = std.meta.stringToEnum(dbm.Kind, v) orelse {
                std.debug.print("unknown db {s}, v1 or v2\n", .{v});
                return error.Usage;
            },
            .ver => r.ver = v,
            .in => r.in = v,
            .out => r.out = v,
            .paths => r.paths = v,
            .bank => r.bank = v,
            .data => r.data = v,
        }
    }
    return r;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    logm.init(io);

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) return usage();
        std.debug.print("unknown command {s}\n", .{args[1]});
        return usage();
    };
    if (cmd == .help) return usage();

    const a = parseArgs(args[2..]) catch return usage();
    const game = a.game orelse {
        std.debug.print("--game is required\n", .{});
        return usage();
    };
    const g = @tagName(game);

    // checked before touching anything
    if (cmd == .append or cmd == .build or cmd == .update) {
        const ver = a.ver orelse {
            std.debug.print("--ver is required for {t}\n", .{cmd});
            return usage();
        };
        // build's goes in the map header, append's (and update's) is only a label in the db
        const ok = if (cmd == .build) map.validVersion(ver) else dbVersion(ver);
        if (!ok) {
            std.debug.print("bad version \"{s}\", need X.Y\n", .{ver});
            return usage();
        }
    }

    const prog = std.Progress.start(io, .{ .root_name = @tagName(cmd) });
    defer prog.end();

    const ctx: utils.Ctx = .{ .io = io, .alloc = arena, .env = init.environ_map, .prog = prog };

    const res: anyerror!void = switch (cmd) {
        .fetch => blk: {
            const out = a.out orelse try std.fmt.allocPrint(arena, "temp/{s}", .{g});
            var f = AudioFetch.init(ctx, game, out) catch |err| break :blk err;
            defer f.deinit();
            break :blk f.fetch();
        },
        .parse => blk: {
            const out = a.out orelse try std.fmt.allocPrint(arena, "{s}.paths.json", .{g});
            const in = a.in orelse try std.fmt.allocPrint(arena, "temp/{s}", .{g});
            _ = AudioParser.parse(ctx, game, in, out) catch |err| break :blk err;
        },
        .append => append(ctx, game, a),
        .build => build(ctx, game, a),
        .update => update(ctx, game, a),
        .help => unreachable,
    };

    res catch |err| {
        std.debug.print("{t} died ({t})\n", .{ cmd, err });
        return 1;
    };
    return 0;
}

fn dbVersion(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// games with a data/<game>.v2 live there and get their paths by hand,
/// the rest are fetched into v1 (a v1 next to a v2 is reference only)
fn activeDb(ctx: utils.Ctx, data: []const u8, game: Game) !dbm.Kind {
    std.Io.Dir.cwd().access(ctx.io, try dbm.zipPath(ctx.alloc, data, game, .v2), .{}) catch return .v1;
    return .v2;
}

fn append(ctx: utils.Ctx, game: Game, a: Args) !void {
    const alloc = ctx.alloc;
    const ver = a.ver.?;
    const kind = a.db orelse try activeDb(ctx, a.data, game);
    // banks alone is fine, otherwise default to what parse writes (v1 only, v2 never sees parse)
    const paths_file: ?[]const u8 = a.paths orelse if (a.bank != null)
        null
    else if (kind == .v1)
        try std.fmt.allocPrint(alloc, "{t}.paths.json", .{game})
    else {
        log.print("{t} is a v2 game, give it a .txt or .tsv with -p", .{game});
        return error.Usage;
    };

    const paths = if (paths_file) |f| (if (pathlist.isText(f))
        pathlist.read(ctx, game, f)
    else
        utils.jsonStringList(alloc, try utils.readJsonFile(ctx, f))) catch |err| {
        log.print("can't read paths {s} ({t})", .{ f, err });
        return err;
    } else null;
    const banks = if (a.bank) |f| try readBanks(ctx, f) else null;

    const zip_path = try dbm.zipPath(alloc, a.data, game, kind);
    log.print("* {t} -> {s}", .{ game, zip_path });
    const db = blk: {
        const node = ctx.prog.start("unzip", 0);
        defer node.end();
        break :blk dbm.Db.openZip(ctx, zip_path) catch |err| switch (err) {
            error.FileNotFound => {
                log.print("> {s} doesn't exist yet, starting a new one", .{zip_path});
                break :blk try dbm.Db.create();
            },
            else => {
                log.print("can't open {s} ({t})", .{ zip_path, err });
                return err;
            },
        };
    };
    defer db.close();

    if (paths) |p| {
        const r = try db.appendPaths(alloc, game, ver, p, ctx.prog);
        log.print("> {s} : {d} paths, {d} new, {d} backdated to {s}", .{ paths_file.?, r.total, r.new, r.backdated, ver });
    }
    if (banks) |b| {
        const r = try db.appendBanks(alloc, game, ver, b);
        log.print("> {s} : {d} banks, {d} new, {d} backdated to {s}", .{ a.bank.?, r.total, r.new, r.backdated, ver });
    }

    {
        const node = ctx.prog.start("zip", 0);
        defer node.end();
        try db.saveZip(ctx, zip_path, try dbm.entryName(alloc, game, kind));
    }
    log.print(">>> {s} ({d} paths, {d} banks)", .{ zip_path, (try db.paths(alloc, game)).len, (try db.banks(alloc, game)).len });
}

fn readBanks(ctx: utils.Ctx, file: []const u8) ![]dbm.Bank {
    const v = utils.readJsonFile(ctx, file) catch |err| {
        log.print("can't read banks {s} ({t})", .{ file, err });
        return err;
    };
    const inner = if (v == .object) v.object.get("banks") else null;
    if (inner == null or inner.? != .object) {
        log.print("{s} isn't {{\"banks\": {{\"<id>\": \"<name>\"}}}}", .{file});
        return error.BadBanks;
    }
    var out: std.ArrayList(dbm.Bank) = .empty;
    var it = inner.?.object.iterator();
    while (it.next()) |kv| {
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, kv.key_ptr.*, " "), 10) catch {
            log.print("bank id {s} in {s} isn't a number", .{ kv.key_ptr.*, file });
            return error.BadBanks;
        };
        if (kv.value_ptr.* != .string) {
            log.print("bank {d} in {s} has no name", .{ id, file });
            return error.BadBanks;
        }
        try out.append(ctx.alloc, .{ .id = id, .name = kv.value_ptr.string });
    }
    return out.items;
}

/// v1 game: fetch + parse + append in one go, the temp files only live for the run
/// v2 game: append of the -p txt/tsv, there's nothing to fetch
fn update(ctx: utils.Ctx, game: Game, a: Args) !void {
    const io = ctx.io;
    const alloc = ctx.alloc;
    const kind = a.db orelse try activeDb(ctx, a.data, game);
    var b = a;
    b.db = kind;

    if (kind == .v2) {
        if (a.paths == null) {
            log.print("{t} is a v2 game, give it a .txt or .tsv with -p", .{game});
            return error.Usage;
        }
        return append(ctx, game, b);
    }
    if (a.paths != null) {
        log.print("{t} is a v1 game, its paths come from fetch, drop -p (or use append)", .{game});
        return error.Usage;
    }

    const work = try std.fmt.allocPrint(alloc, "temp/{t}", .{game});
    const paths_file = try std.fs.path.join(alloc, &.{ work, "paths.json" });

    {
        var f = try AudioFetch.init(ctx, game, work);
        defer f.deinit();
        try f.fetch();
    }
    _ = try AudioParser.parse(ctx, game, work, paths_file);

    b.paths = paths_file;
    append(ctx, game, b) catch |err| {
        log.print("{s} is left there, rerun append on it once fixed", .{paths_file});
        return err;
    };

    // only reached on success, a failed step keeps its files around to look at
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, work);
    cwd.deleteDir(io, "temp") catch {}; // only goes if nothing else is in there
    log.print("> cleaned up {s}", .{work});
}

fn build(ctx: utils.Ctx, game: Game, a: Args) !void {
    const alloc = ctx.alloc;
    const kind = a.db orelse .v1;
    const zip_path = try dbm.zipPath(alloc, a.data, game, kind);
    const db = blk: {
        const node = ctx.prog.start("unzip", 0);
        defer node.end();
        break :blk dbm.Db.openZip(ctx, zip_path) catch |err| {
            log.print("can't open {s} ({t})", .{ zip_path, err });
            return err;
        };
    };
    defer db.close();

    const paths = try db.paths(alloc, game);
    const banks = try db.banks(alloc, game);
    log.print("* {s} : {d} paths, {d} banks", .{ zip_path, paths.len, banks.len });

    const ver = a.ver.?;
    const out = a.out orelse try std.fmt.allocPrint(alloc, "{t}-{s}.{t}.map", .{ game, ver, kind });
    _ = try map.build(ctx, .{ .game = game, .ver = ver, .paths = paths, .banks = banks, .out = out });
}

fn usage() u8 {
    std.debug.print(
        \\usage: wwisemap <command> -g <hk4e|hkrpg|nap|beyond> [options]
        \\
        \\  fetch   download the raw audio tables for a game
        \\            -o, --out <dir>       where to put them      (temp/<game>)
        \\
        \\  parse   turn the raw tables into a json list of wem paths
        \\            -i, --in <dir>        fetch output           (temp/<game>)
        \\            -o, --out <file>      paths list             (<game>.paths.json)
        \\
        \\  append  merge a paths list (and/or banks) into data/<game>.<db>
        \\            -v, --ver <X.Y>       version they're from   (required)
        \\            -p, --paths <file>    .json, .txt or .tsv    (v1: <game>.paths.json unless only -b, v2: required)
        \\            -b, --bank <file>     {{"banks": {{...}}}} json  (none)
        \\            -d, --db <v1|v2>      which db               (v2 if data/<game>.v2 exists, else v1)
        \\                --data <dir>      db folder              (data)
        \\
        \\  build   turn every path and bank of data/<game>.<db> into a .map
        \\            -v, --ver <X.Y>       game version, for the map header (required)
        \\            -d, --db <v1|v2>      which db               (v1)
        \\            -o, --out <file>      output map             (<game>-<ver>.<db>.map)
        \\                --data <dir>      db folder              (data)
        \\
        \\  update  v1 game: fetch + parse + append, then delete the temp files
        \\          v2 game (has data/<game>.v2): append the -p file to v2
        \\            -v, --ver <X.Y>       version it's from      (required)
        \\            -p, --paths <file>    .txt or .tsv           (v2 only, required there)
        \\            -b, --bank <file>     {{"banks": {{...}}}} json  (none)
        \\                --data <dir>      db folder              (data)
        \\
    , .{});
    return 2;
}

test {
    _ = @import("pyrandom.zig");
    _ = @import("map.zig");
    _ = @import("utils.zig");
    _ = @import("zip.zig");
    _ = @import("db.zig");
    _ = @import("pathlist.zig");
}
