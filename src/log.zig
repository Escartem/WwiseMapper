//! UAEPT::lib::log

const std = @import("std");
const Io = std.Io;

pub const Scope = enum {
    utils,
    wwiseMap,
    AudioFetch,
    AudioParser,
    db,
};

var io: Io = undefined;
var start: Io.Timestamp = undefined;

pub fn init(_io: Io) void {
    io = _io;
    start = Io.Clock.awake.now(io);
}

pub fn print(scope: Scope, comptime fmt: []const u8, args: anytype) void {
    const ms = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    // goes through the stderr lock so the progress bar gets cleared and redrawn around it
    std.debug.print("{d:>4}.{d:0>3}s [{t}] " ++ fmt ++ "\n", .{ @divTrunc(ms, 1000), @as(u64, @intCast(@mod(ms, 1000))), scope } ++ args);
}

pub fn scoped(comptime scope: Scope) type {
    return struct {
        pub fn print(comptime fmt: []const u8, args: anytype) void {
            log_print(scope, fmt, args);
        }
    };
}

const log_print = print;
