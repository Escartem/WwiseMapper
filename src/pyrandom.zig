//! random.Random(42).shuffle() 1:1
//! strings sector order has to match v2 or old maps and new maps don't diff

const std = @import("std");

const N = 624;
const M = 397;

pub const Random = struct {
    mt: [N]u32 = undefined,
    mti: usize = N + 1,

    pub fn init(seed: u64) Random {
        var r: Random = .{};
        // _random_Random_seed_impl -> abs(int) split in 32bit chunks
        var key: [2]u32 = .{ @truncate(seed), @truncate(seed >> 32) };
        const used: usize = if (key[1] != 0) 2 else 1;
        r.initByArray(key[0..used]);
        return r;
    }

    fn initGenrand(r: *Random, s: u32) void {
        r.mt[0] = s;
        var i: usize = 1;
        while (i < N) : (i += 1) {
            r.mt[i] = 1812433253 *% (r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) +% @as(u32, @intCast(i));
        }
        r.mti = N;
    }

    fn initByArray(r: *Random, key: []const u32) void {
        r.initGenrand(19650218);
        var i: usize = 1;
        var j: usize = 0;
        var k: usize = @max(N, key.len);
        while (k > 0) : (k -= 1) {
            r.mt[i] = (r.mt[i] ^ ((r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) *% 1664525)) +% key[j] +% @as(u32, @intCast(j));
            i += 1;
            j += 1;
            if (i >= N) {
                r.mt[0] = r.mt[N - 1];
                i = 1;
            }
            if (j >= key.len) j = 0;
        }
        k = N - 1;
        while (k > 0) : (k -= 1) {
            r.mt[i] = (r.mt[i] ^ ((r.mt[i - 1] ^ (r.mt[i - 1] >> 30)) *% 1566083941)) -% @as(u32, @intCast(i));
            i += 1;
            if (i >= N) {
                r.mt[0] = r.mt[N - 1];
                i = 1;
            }
        }
        r.mt[0] = 0x80000000;
    }

    fn genrand(r: *Random) u32 {
        const mag01 = [2]u32{ 0, 0x9908b0df };
        if (r.mti >= N) {
            var kk: usize = 0;
            while (kk < N - M) : (kk += 1) {
                const y = (r.mt[kk] & 0x80000000) | (r.mt[kk + 1] & 0x7fffffff);
                r.mt[kk] = r.mt[kk + M] ^ (y >> 1) ^ mag01[y & 1];
            }
            while (kk < N - 1) : (kk += 1) {
                const y = (r.mt[kk] & 0x80000000) | (r.mt[kk + 1] & 0x7fffffff);
                r.mt[kk] = r.mt[kk + M - N] ^ (y >> 1) ^ mag01[y & 1];
            }
            const y = (r.mt[N - 1] & 0x80000000) | (r.mt[0] & 0x7fffffff);
            r.mt[N - 1] = r.mt[M - 1] ^ (y >> 1) ^ mag01[y & 1];
            r.mti = 0;
        }
        var y = r.mt[r.mti];
        r.mti += 1;
        y ^= (y >> 11);
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= (y >> 18);
        return y;
    }

    // getrandbits(k), k <= 32 is all shuffle ever needs below 4B entries
    fn getrandbits(r: *Random, k: u6) u32 {
        return r.genrand() >> @intCast(32 - @as(u32, k));
    }

    // _randbelow_with_getrandbits
    fn randbelow(r: *Random, n: usize) usize {
        const k: u6 = @intCast(std.math.log2_int(usize, n) + 1);
        var v = r.getrandbits(k);
        while (v >= n) v = r.getrandbits(k);
        return v;
    }

    pub fn shuffle(r: *Random, comptime T: type, x: []T) void {
        if (x.len < 2) return;
        var i: usize = x.len - 1;
        while (i >= 1) : (i -= 1) {
            const j = r.randbelow(i + 1);
            std.mem.swap(T, &x[i], &x[j]);
        }
    }
};

test "big list" {
    const a = try std.testing.allocator.alloc(u32, 70000);
    defer std.testing.allocator.free(a);
    for (a, 0..) |*e, i| e.* = @intCast(i);
    var r = Random.init(42);
    r.shuffle(u32, a);
    try std.testing.expectEqualSlices(u32, &.{ 21209, 63787, 69973, 60535, 51656, 57672, 32513, 23436 }, a[0..8]);
    try std.testing.expectEqualSlices(u32, &.{ 29256, 32098, 36048, 3278, 14592 }, a[a.len - 5 ..]);
}
