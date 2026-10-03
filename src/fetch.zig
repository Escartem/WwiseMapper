//! UAEPT::lib::mod::wwiseMap::AudioFetch

const std = @import("std");
const Io = std.Io;
const utils = @import("utils.zig");
const Game = utils.Game;
const log = @import("log.zig").scoped(.AudioFetch);

pub const AudioFetch = struct {
    ctx: utils.Ctx,
    game: Game,
    out: []const u8,
    client: std.http.Client,

    pub fn init(ctx: utils.Ctx, game: Game, out: []const u8) !AudioFetch {
        var self: AudioFetch = .{
            .ctx = ctx,
            .game = game,
            .out = out,
            .client = .{ .allocator = ctx.alloc, .io = ctx.io },
        };
        // corpo networks & sandboxes
        try self.client.initDefaultProxies(ctx.alloc, ctx.env);
        return self;
    }

    pub fn deinit(self: *AudioFetch) void {
        self.client.deinit();
    }

    pub fn fetch(self: *AudioFetch) !void {
        // hk4e -> gitlab & Dimbreath & animegamedata2
        // hkrpg -> gitlab & Dimbreath & turnbasedgamedata
        // nap -> gitmeromoe & dimbreath & ZenlessData
        // beyond -> github & Dimbreath & EndfieldData
        const io = self.ctx.io;
        const alloc = self.ctx.alloc;
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.out);

        switch (self.game) {
            .hk4e => {
                // i fucking hate gi
                const zip_path = try self.sub("data.zip");
                const extract_path = try self.sub("extract");
                const items_path = try self.sub("items");

                try self.downloadRaw("https://gitlab.com/Dimbreath/animegamedata2/-/archive/main/animegamedata2-main.zip?ref_type=heads&path=BinOutput/Voice/Items", zip_path);

                cwd.deleteTree(io, extract_path) catch {};
                {
                    log.print("> extracting {s}", .{zip_path});
                    const node = self.ctx.prog.start("extract", 0);
                    defer node.end();
                    var zip_file = try cwd.openFile(io, zip_path, .{});
                    defer zip_file.close(io);
                    var buf: [64 * 1024]u8 = undefined;
                    var fr = zip_file.reader(io, &buf);
                    try cwd.createDirPath(io, extract_path);
                    var out = try cwd.openDir(io, extract_path, .{});
                    defer out.close(io);
                    try std.zip.extract(out, &fr, .{});
                }

                // archive root is named after the repo + path
                const top = blk: {
                    var dir = try cwd.openDir(io, extract_path, .{ .iterate = true });
                    defer dir.close(io);
                    var it = dir.iterate();
                    while (try it.next(io)) |e| if (e.kind == .directory) break :blk try alloc.dupe(u8, e.name);
                    log.print("{s} is empty ???", .{zip_path});
                    return error.BadArchive;
                };
                const src = try std.fs.path.join(alloc, &.{ extract_path, top, "BinOutput", "Voice", "Items" });

                cwd.deleteTree(io, items_path) catch {};
                try cwd.rename(src, cwd, items_path, io);
                try cwd.deleteTree(io, extract_path);
                try cwd.deleteFile(io, zip_path);
                log.print("> {s} ready", .{items_path});
            },
            .hkrpg => {
                try self.download("https://gitlab.com/Dimbreath/turnbasedgamedata/-/raw/main/ExcelOutput/VoiceConfig.json?inline=false", "VoiceConfig");
                try self.download("https://gitlab.com/Dimbreath/turnbasedgamedata/-/raw/main/ExcelOutput/ResourceDeletionVPList.json?inline=false", "ResourceDeletionVPList");
                try self.download("https://gitlab.com/Dimbreath/turnbasedgamedata/-/raw/main/ExcelOutput/SFXConfig.json?inline=false", "SFXConfig");
            },
            .nap => try self.download("https://git.mero.moe/dimbreath/ZenlessData/raw/branch/master/Data/JsonBytes/Audio/AudioResourceData.json", "AudioResourceData"),
            .beyond => try self.download("https://git.escartem.moe/Escartem/EndfieldData/raw/branch/master/TableCfg/AudioDialog.json", "AudioDialog"),
        }
    }

    fn sub(self: *AudioFetch, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.ctx.alloc, &.{ self.out, name });
    }

    fn download(self: *AudioFetch, url: []const u8, name: []const u8) !void {
        const path = try self.sub(try std.fmt.allocPrint(self.ctx.alloc, "{s}.json", .{name}));
        try self.downloadRaw(url, path);

        const raw = try Io.Dir.cwd().readFileAlloc(self.ctx.io, path, self.ctx.alloc, .unlimited);
        if (!try std.json.validate(self.ctx.alloc, raw)) {
            log.print("{s} is not json ???", .{path});
            return error.InvalidJson;
        }
    }

    // streams straight to disk, the gi zip is a fatass
    fn downloadRaw(self: *AudioFetch, url: []const u8, path: []const u8) !void {
        const io = self.ctx.io;
        log.print("> GET {s}", .{url});

        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(io, &buf);

        var req = try self.client.request(.GET, try std.Uri.parse(url), .{});
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        const status = response.head.status;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.ctx.alloc.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.ctx.alloc.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };

        const total_kb: usize = if (response.head.content_length) |l| @intCast(l / 1024) else 0;
        const node = self.ctx.prog.startFmt(total_kb, "GET {s} (KiB)", .{std.fs.path.basename(path)});
        defer node.end();

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        var done: usize = 0;
        while (true) {
            done += reader.stream(&fw.interface, .limited(64 * 1024)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr().?,
                else => |e| return e,
            };
            node.setCompletedItems(done / 1024);
        }
        try fw.interface.flush();

        var sz: [32]u8 = undefined;
        log.print("> {d} {t} -> {s} ({s})", .{ @intFromEnum(status), status, path, utils.fmtBytes(&sz, fw.pos) });
        if (status != .ok) return error.BadStatus;
    }
};
