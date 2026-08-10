// A fixed-buffer-backed hash map cache.
///
/// Remembers the *output* of expensive work (rasterized text, decoded images)
/// keyed by a hash of the *input* that produced it — a string, an image source,
/// a path — never by the pixel bytes themselves. A `Cache` owns a fixed slab of
/// memory that backs the map's bookkeeping (buckets, hash table growth). The
/// cached values themselves are slices into a caller-owned long-lived allocator
/// (`Context.arena`), so they stay valid across frames.
///
/// Because the allocation budget is fixed up front, the cache can never grow
/// without bound: when the slab is exhausted a fresh entry is simply not cached
/// (callers fall back to computing it), and everything already in the cache
/// stays valid.
const std = @import("std");

pub fn Cache(comptime Key: type, comptime Value: type, comptime BucketBytes: comptime_int) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMapUnmanaged(Key, Value);

        buf: [BucketBytes]u8 align(@alignOf(usize)) = undefined,
        fba: std.heap.FixedBufferAllocator = undefined,
        map: Map = .{},
        ready: bool = false,

        pub fn get(self: *Self, key: Key) ?Value {
            self.ensure();
            return self.map.get(key);
        }

        /// Returns a pointer to the stored value so callers can mutate it in
        /// place (bump a last-seen frame counter) without replacing the whole
        /// entry.
        pub fn getMutable(self: *Self, key: Key) ?*Value {
            self.ensure();
            return self.map.getPtr(key);
        }

        /// Removes a single entry without freeing its value; the caller owns the
        /// value (it may be an SDL texture torn down explicitly on eviction).
        pub fn remove(self: *Self, key: Key) void {
            self.ensure();
            _ = self.map.remove(key);
        }

        pub fn put(self: *Self, key: Key, value: Value) void {
            self.ensure();
            self.map.put(self.fba.allocator(), key, value) catch {};
        }

        /// Number of live entries (not the slab's capacity).
        pub fn count(self: *Self) usize {
            self.ensure();
            return self.map.count();
        }

        /// Empties the map without freeing values; the caller owns them (they
        /// are SDL textures in `Window`'s shadow cache, torn down explicitly).
        pub fn clear(self: *Self) void {
            self.ensure();
            self.map.clearRetainingCapacity();
        }

        /// Iterates all live entries (for tearing down values the cache itself
        /// cannot free, like SDL textures).
        pub fn iterator(self: *Self) Map.Iterator {
            self.ensure();
            return self.map.iterator();
        }

        fn ensure(self: *Self) void {
            if (self.ready) return;
            self.fba = std.heap.FixedBufferAllocator.init(&self.buf);
            self.ready = true;
        }
    };
}
