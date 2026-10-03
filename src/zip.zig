//! the data/ dbs are zips holding a single <game>.<v1|v2>.db
//! std.zip only extracts to a dir, this reads one entry into memory and writes single entry zips back

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zip = std.zip;
const flate = std.compress.flate;

/// first entry whose name ends with `suffix`, decompressed and crc checked
pub fn readEntry(io: Io, alloc: Allocator, path: []const u8, suffix: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);

    var it = try zip.Iterator.init(&fr);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |e| {
        if (e.filename_len > name_buf.len) return error.ZipInsufficientBuffer;
        const name = name_buf[0..e.filename_len];
        try fr.seekTo(e.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        if (!std.mem.endsWith(u8, name, suffix)) continue;

        try fr.seekTo(e.file_offset);
        const lh = try fr.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &lh.signature, &zip.local_file_header_sig)) return error.ZipBadFileOffset;
        try fr.seekTo(e.file_offset + @sizeOf(zip.LocalFileHeader) + lh.filename_len + lh.extra_len);

        const out = try alloc.alloc(u8, @intCast(e.uncompressed_size));
        switch (e.compression_method) {
            .store => try fr.interface.readSliceAll(out),
            .deflate => {
                const window = try alloc.alloc(u8, flate.max_window_len);
                defer alloc.free(window);
                var d: flate.Decompress = .init(&fr.interface, .raw, window);
                d.reader.readSliceAll(out) catch |err| return d.err orelse err;
            },
            else => return error.UnsupportedCompressionMethod,
        }
        if (std.hash.Crc32.hash(out) != e.crc32) return error.ZipMismatchCrc32;
        return out;
    }
    return error.ZipEntryNotFound;
}

/// zip with a single deflated entry, written next to `path` first then renamed over it
pub fn writeSingle(io: Io, alloc: Allocator, path: []const u8, name: []const u8, data: []const u8) !void {
    if (data.len > std.math.maxInt(u32)) return error.ZipTooBig; // would need zip64

    var aw: Io.Writer.Allocating = try .initCapacity(alloc, data.len / 4 + 64);
    defer aw.deinit();
    {
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        var c = try flate.Compress.init(&aw.writer, window, .raw, .default);
        try c.writer.writeAll(data);
        try c.finish();
    }
    const comp = aw.written();
    if (comp.len > std.math.maxInt(u32)) return error.ZipTooBig;

    const crc = std.hash.Crc32.hash(data);
    const time, const date = dosNow(io);

    const lh: zip.LocalFileHeader = .{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .deflate,
        .last_modification_time = time,
        .last_modification_date = date,
        .crc32 = crc,
        .compressed_size = @intCast(comp.len),
        .uncompressed_size = @intCast(data.len),
        .filename_len = @intCast(name.len),
        .extra_len = 0,
    };
    const cd: zip.CentralDirectoryFileHeader = .{
        .signature = zip.central_file_header_sig,
        .version_made_by = 20,
        .version_needed_to_extract = 20,
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .deflate,
        .last_modification_time = time,
        .last_modification_date = date,
        .crc32 = crc,
        .compressed_size = @intCast(comp.len),
        .uncompressed_size = @intCast(data.len),
        .filename_len = @intCast(name.len),
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0,
        .local_file_header_offset = 0,
    };
    const cd_offset = @sizeOf(zip.LocalFileHeader) + name.len + comp.len;
    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @intCast(@sizeOf(zip.CentralDirectoryFileHeader) + name.len),
        .central_directory_offset = @intCast(cd_offset),
        .comment_len = 0,
    };

    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    {
        var file = try Io.Dir.cwd().createFile(io, tmp, .{});
        defer file.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        const w = &fw.interface;
        try w.writeStruct(lh, .little);
        try w.writeAll(name);
        try w.writeAll(comp);
        try w.writeStruct(cd, .little);
        try w.writeAll(name);
        try w.writeStruct(end, .little);
        try w.flush();
    }
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

fn dosNow(io: Io) struct { u16, u16 } {
    const secs: u64 = @intCast(@max(0, Io.Clock.real.now(io).toSeconds()));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const year: u16 = @max(yd.year, 1980) - 1980;
    const date: u16 = (year << 9) | (@as(u16, md.month.numeric()) << 5) | (@as(u16, md.day_index) + 1);
    const time: u16 = (@as(u16, ds.getHoursIntoDay()) << 11) | (@as(u16, ds.getMinutesIntoHour()) << 5) | (ds.getSecondsIntoMinute() / 2);
    return .{ time, date };
}

test "write then read back" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: [100_000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 ^ (i >> 7));

    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/test.v1", .{tmp.sub_path});
    defer a.free(path);
    try writeSingle(io, a, path, "test.v1.db", &data);
    const back = try readEntry(io, a, path, ".db");
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, &data, back);
}
