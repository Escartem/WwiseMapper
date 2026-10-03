const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const zip = @import("zip.zig");
const log = @import("log.zig").scoped(.db);

pub const Kind = enum { v1, v2 };

pub const schema =
    \\CREATE TABLE IF NOT EXISTS paths (
    \\    game    TEXT NOT NULL,
    \\    path    TEXT NOT NULL,
    \\    version TEXT,
    \\    UNIQUE (game, path)
    \\);
    \\CREATE TABLE IF NOT EXISTS banks (
    \\    game    TEXT NOT NULL,
    \\    id      INTEGER NOT NULL,
    \\    name    TEXT NOT NULL,
    \\    version TEXT,
    \\    UNIQUE (game, id)
    \\);
;

pub const Bank = struct { id: u32, name: []const u8 };

pub fn zipPath(alloc: Allocator, data_dir: []const u8, game: utils.Game, kind: Kind) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{t}.{t}", .{ data_dir, game, kind });
}

pub fn entryName(alloc: Allocator, game: utils.Game, kind: Kind) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{t}.{t}.db", .{ game, kind });
}

pub const Db = struct {
    h: *c.sqlite3,

    /// empty db with the schema, for a game that has no data/ file yet
    pub fn create() !Db {
        const db = try openMemory();
        try db.exec(schema);
        return db;
    }

    pub fn openZip(ctx: utils.Ctx, path: []const u8) !Db {
        const raw = try zip.readEntry(ctx.io, ctx.alloc, path, ".db");
        defer ctx.alloc.free(raw);

        const db = try openMemory();
        errdefer db.close();
        // sqlite owns the buffer from here, so it has to come from its allocator
        const buf = c.sqlite3_malloc64(raw.len) orelse return error.OutOfMemory;
        @memcpy(buf[0..raw.len], raw);
        const flags = c.DESERIALIZE_FREEONCLOSE | c.DESERIALIZE_RESIZEABLE;
        try db.check(c.sqlite3_deserialize(db.h, "main", buf, @intCast(raw.len), @intCast(raw.len), flags));
        // also catches a zip that holds something else than a sqlite db
        try db.exec(schema);
        return db;
    }

    fn openMemory() !Db {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(":memory:", &h, c.OPEN_READWRITE | c.OPEN_CREATE, null) != c.OK) {
            if (h) |x| _ = c.sqlite3_close(x);
            return error.SqliteOpen;
        }
        return .{ .h = h.? };
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close(db.h);
    }

    pub fn saveZip(db: Db, ctx: utils.Ctx, path: []const u8, name: []const u8) !void {
        var size: i64 = 0;
        const bytes = c.sqlite3_serialize(db.h, "main", &size, 0) orelse return error.OutOfMemory;
        defer c.sqlite3_free(bytes);
        try utils.makeParent(ctx, path);
        try zip.writeSingle(ctx.io, ctx.alloc, path, name, bytes[0..@intCast(size)]);
    }

    pub fn exec(db: Db, sql: [:0]const u8) !void {
        try db.check(c.sqlite3_exec(db.h, sql, null, null, null));
    }

    pub fn prepare(db: Db, sql: []const u8) !Stmt {
        var s: ?*c.sqlite3_stmt = null;
        try db.check(c.sqlite3_prepare_v2(db.h, sql.ptr, @intCast(sql.len), &s, null));
        return .{ .db = db, .h = s.? };
    }

    fn check(db: Db, rc: c_int) !void {
        if (rc == c.OK) return;
        log.print("sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(db.h))});
        return error.Sqlite;
    }

    /// every path of `game`, in the order they were added
    pub fn paths(db: Db, alloc: Allocator, game: utils.Game) ![][]const u8 {
        const s = try db.prepare("SELECT path FROM paths WHERE game = ?1 ORDER BY rowid");
        defer s.finalize();
        try s.bindText(1, @tagName(game));
        var out: std.ArrayList([]const u8) = .empty;
        while (try s.step()) try out.append(alloc, try alloc.dupe(u8, s.text(0) orelse return error.Corrupt));
        return out.items;
    }

    pub fn banks(db: Db, alloc: Allocator, game: utils.Game) ![]Bank {
        const s = try db.prepare("SELECT id, name FROM banks WHERE game = ?1 ORDER BY rowid");
        defer s.finalize();
        try s.bindText(1, @tagName(game));
        var out: std.ArrayList(Bank) = .empty;
        while (try s.step()) {
            const id = std.math.cast(u32, s.int(0)) orelse return error.Corrupt;
            try out.append(alloc, .{ .id = id, .name = try alloc.dupe(u8, s.text(1) orelse return error.Corrupt) });
        }
        return out.items;
    }

    pub const Added = struct { total: usize, new: usize = 0, backdated: usize = 0 };

    /// first seen
    pub fn appendPaths(db: Db, alloc: Allocator, game: utils.Game, version: []const u8, list: []const []const u8, prog: std.Progress.Node) !Added {
        const g = @tagName(game);
        var known = try db.loadVersions([]const u8, alloc, "SELECT path, version FROM paths WHERE game = ?1", g);

        const ins = try db.prepare("INSERT INTO paths (game, path, version) VALUES (?1, ?2, ?3)");
        defer ins.finalize();
        const upd = try db.prepare("UPDATE paths SET version = ?3 WHERE game = ?1 AND path = ?2");
        defer upd.finalize();

        const node = prog.start("paths", list.len);
        defer node.end();

        var res: Added = .{ .total = 0 };
        try db.exec("BEGIN");
        errdefer db.exec("ROLLBACK") catch {};
        for (list, 0..) |p, i| {
            if (i % 4096 == 0) node.setCompletedItems(i);
            if (p.len == 0) continue; // empty security
            res.total += 1;
            const gop = try known.getOrPut(alloc, p);
            const s = if (!gop.found_existing) blk: {
                res.new += 1;
                break :blk ins;
            } else if (older(version, gop.value_ptr.*)) blk: {
                res.backdated += 1;
                break :blk upd;
            } else continue;
            gop.value_ptr.* = version;
            try s.bindText(1, g);
            try s.bindText(2, p);
            try s.bindText(3, version);
            try s.run();
        }
        try db.exec("COMMIT");
        return res;
    }

    pub fn appendBanks(db: Db, alloc: Allocator, game: utils.Game, version: []const u8, list: []const Bank) !Added {
        const g = @tagName(game);
        var known = try db.loadVersions(u32, alloc, "SELECT id, version FROM banks WHERE game = ?1", g);
        var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        {
            const s = try db.prepare("SELECT id, name FROM banks WHERE game = ?1");
            defer s.finalize();
            try s.bindText(1, g);
            while (try s.step()) try names.put(alloc, @intCast(s.int(0)), try alloc.dupe(u8, s.text(1).?));
        }

        const ins = try db.prepare("INSERT INTO banks (game, id, name, version) VALUES (?1, ?2, ?3, ?4)");
        defer ins.finalize();
        const upd = try db.prepare("UPDATE banks SET version = ?4 WHERE game = ?1 AND id = ?2");
        defer upd.finalize();

        var res: Added = .{ .total = list.len };
        var renamed: usize = 0;
        try db.exec("BEGIN");
        errdefer db.exec("ROLLBACK") catch {};
        for (list) |b| {
            // ids aren't name hashes
            if (names.get(b.id)) |old| if (!std.mem.eql(u8, old, b.name)) {
                renamed += 1;
                if (renamed <= 10) log.print("! bank {d} is \"{s}\" in {s}, keeping \"{s}\"", .{ b.id, b.name, version, old });
            };
            const gop = try known.getOrPut(alloc, b.id);
            const s = if (!gop.found_existing) blk: {
                res.new += 1;
                break :blk ins;
            } else if (older(version, gop.value_ptr.*)) blk: {
                res.backdated += 1;
                break :blk upd;
            } else continue;
            gop.value_ptr.* = version;
            try s.bindText(1, g);
            try s.bindInt(2, b.id);
            try s.bindText(3, b.name);
            try s.bindText(4, version);
            try s.run();
        }
        try db.exec("COMMIT");
        if (renamed > 10) log.print("! ... {d} more renamed banks", .{renamed - 10});
        return res;
    }

    fn loadVersions(db: Db, comptime K: type, alloc: Allocator, sql: []const u8, g: []const u8) !(if (K == u32)
        std.AutoHashMapUnmanaged(u32, ?[]const u8)
    else
        std.StringHashMapUnmanaged(?[]const u8)) {
        var out: (if (K == u32) std.AutoHashMapUnmanaged(u32, ?[]const u8) else std.StringHashMapUnmanaged(?[]const u8)) = .empty;
        const s = try db.prepare(sql);
        defer s.finalize();
        try s.bindText(1, g);
        while (try s.step()) {
            const key: K = if (K == u32) @intCast(s.int(0)) else try alloc.dupe(u8, s.text(0).?);
            const v: ?[]const u8 = if (s.text(1)) |t| try alloc.dupe(u8, t) else null;
            try out.put(alloc, key, v);
        }
        return out;
    }
};

// untagged rows (v2's originals) predate every version, they stay untagged
fn older(new: []const u8, cur: ?[]const u8) bool {
    return if (cur) |v| utils.versionLess(new, v) else false;
}

pub const Stmt = struct {
    db: Db,
    h: *c.sqlite3_stmt,

    pub fn finalize(s: Stmt) void {
        _ = c.sqlite3_finalize(s.h);
    }

    /// true while there's a row
    pub fn step(s: Stmt) !bool {
        return switch (c.sqlite3_step(s.h)) {
            c.ROW => true,
            c.DONE => false,
            else => |rc| {
                try s.db.check(rc);
                unreachable;
            },
        };
    }

    /// for writes, steps once and resets so it can be bound again
    pub fn run(s: Stmt) !void {
        _ = try s.step();
        try s.db.check(c.sqlite3_reset(s.h));
    }

    // static, every string we bind outlives the statement step
    pub fn bindText(s: Stmt, i: c_int, v: []const u8) !void {
        try s.db.check(c.sqlite3_bind_text(s.h, i, v.ptr, @intCast(v.len), null));
    }

    pub fn bindInt(s: Stmt, i: c_int, v: i64) !void {
        try s.db.check(c.sqlite3_bind_int64(s.h, i, v));
    }

    /// null for SQL NULL, points into sqlite until the next step
    pub fn text(s: Stmt, i: c_int) ?[]const u8 {
        if (c.sqlite3_column_type(s.h, i) == c.NULL) return null;
        const p = c.sqlite3_column_text(s.h, i) orelse return "";
        return p[0..@intCast(c.sqlite3_column_bytes(s.h, i))];
    }

    pub fn int(s: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(s.h, i);
    }
};

/// the few bits of sqlite3.h we use, built from the amalgamation in build.zig
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};

    const OK = 0;
    const ROW = 100;
    const DONE = 101;
    const NULL = 5;
    const OPEN_READWRITE = 0x02;
    const OPEN_CREATE = 0x04;
    const DESERIALIZE_FREEONCLOSE = 1;
    const DESERIALIZE_RESIZEABLE = 2;

    extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
    extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, i: c_int, v: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
    extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, v: i64) c_int;
    extern fn sqlite3_column_type(stmt: *sqlite3_stmt, i: c_int) c_int;
    extern fn sqlite3_column_text(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
    extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;
    extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, i: c_int) i64;
    extern fn sqlite3_malloc64(n: u64) ?[*]u8;
    extern fn sqlite3_free(p: ?*anyopaque) void;
    extern fn sqlite3_deserialize(db: *sqlite3, schema: [*:0]const u8, data: [*]u8, size: i64, buf_size: i64, flags: c_uint) c_int;
    extern fn sqlite3_serialize(db: *sqlite3, schema: [*:0]const u8, size: *i64, flags: c_uint) ?[*]u8;
};

test "append keeps the first version" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try Db.create();
    defer db.close();

    var r = try db.appendPaths(a, .hk4e, "5.0", &.{ "A\\b", "A\\c", "" }, .none);
    try std.testing.expectEqual(Db.Added{ .total = 2, .new = 2 }, r);
    // newer version: nothing moves, one new row
    r = try db.appendPaths(a, .hk4e, "5.10", &.{ "A\\b", "A\\d" }, .none);
    try std.testing.expectEqual(Db.Added{ .total = 2, .new = 1 }, r);
    // older version: backdates the row it shares
    r = try db.appendPaths(a, .hk4e, "4.9", &.{"A\\d"}, .none);
    try std.testing.expectEqual(Db.Added{ .total = 1, .backdated = 1 }, r);
    // other games don't leak in
    _ = try db.appendPaths(a, .nap, "1.0", &.{"Ex\\x"}, .none);

    const p = try db.paths(a, .hk4e);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("A\\d", p[2]);

    const br = try db.appendBanks(a, .hk4e, "5.3", &.{ .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "two" } });
    try std.testing.expectEqual(Db.Added{ .total = 2, .new = 2 }, br);
    const b = try db.banks(a, .hk4e);
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqualStrings("two", b[1].name);
}
