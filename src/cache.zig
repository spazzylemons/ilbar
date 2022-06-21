const allocator = @import("main.zig").allocator;
const std = @import("std");

/// A generic hashtable cache.
pub fn Cache(comptime K: type, comptime V: type, comptime Callbacks: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: ?K = null,
            value: V = undefined,
        };

        const List = std.TailQueue(Entry);

        /// The number of entries used.
        load: usize = 0,
        /// The entries in the cache.
        entries: []List.Node,
        /// The used entries in the cache, sorted by least recently used.
        recent: List = .{},

        pub fn init(size: usize) !Self {
            const entries = try allocator.alloc(List.Node, size);
            errdefer allocator.free(entries);

            for (entries) |*entry| {
                entry.* = .{ .data = .{} };
            }

            return Self{ .entries = entries };
        }

        pub fn deinit(self: Self) void {
            for (self.entries) |entry| {
                if (entry.data.key) |key| {
                    Callbacks.free(key, entry.data.value);
                }
            }
            allocator.free(self.entries);
        }

        pub fn get(self: *Self, key: K) ?V {
            const hash = Callbacks.hash(key);
            var index = hash % self.entries.len;
            while (true) : (index = (index + 1) % self.entries.len) {
                const entry = &self.entries[index];
                const other_key = entry.data.key orelse return null;
                if (Callbacks.equal(key, other_key)) {
                    // move entry to tail of list
                    self.recent.remove(entry);
                    self.recent.append(entry);
                    return entry.data.value;
                }
            }
        }

        pub fn put(self: *Self, key: K, value: V) void {
            // need at least one free space always available
            if (self.load + 1 == self.entries.len) {
                // get least recently used
                const oldest = self.recent.first.?;
                // free its contents
                Callbacks.free(oldest.data.key.?, oldest.data.value);
                // remove from list
                self.recent.remove(oldest);
                // shift over rest of chain
                var index = (@ptrToInt(oldest) - @ptrToInt(self.entries.ptr)) / @sizeOf(List.Node);
                while (true) {
                    const next = (index + 1) % self.entries.len;
                    const entry1 = &self.entries[index];
                    const entry2 = &self.entries[next];
                    entry1.data = entry2.data;
                    if (entry2.data.key == null) {
                        if (entry1.data.key != null) {
                            self.recent.remove(entry1);
                        }
                        break;
                    }
                    index = next;
                }
                // free up space
                self.load -= 1;
            }
            // find a spot to put the new element
            const hash = Callbacks.hash(key);
            var index = hash % self.entries.len;
            while (true) : (index = (index + 1) % self.entries.len) {
                const entry = &self.entries[index];
                if (entry.data.key) |other_key| {
                    if (Callbacks.equal(key, other_key)) {
                        // move entry to tail of list
                        self.recent.remove(entry);
                        self.recent.append(entry);
                        // free the old value
                        Callbacks.free(other_key, entry.data.value);
                        // put in the new value
                        entry.data.key = key;
                        entry.data.value = value;
                        return;
                    }
                } else {
                    // use the unused entry
                    entry.data.key = key;
                    entry.data.value = value;
                    self.recent.append(entry);
                    self.load += 1;
                    return;
                }
            }
        }
    };
}
