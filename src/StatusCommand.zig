const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");
const util = @import("util.zig");

const StatusCommand = @This();

status: []const u8 = &.{},
status_buffer: std.ArrayListUnmanaged(u8) = .{},
process: ?std.ChildProcess = null,
process_running: bool = false,

const CommandSource = struct {
    source: c.GSource,
    // pfd: c.GPollFD,
    cond: c.GIOCondition,
    tag: c.gpointer,
    status_command: *StatusCommand,

    fn prepare(source: ?*c.GSource, timeout: ?*c.gint) callconv(.C) c.gboolean {
        _ = source;
        timeout.?.* = -1;
        return 0;
    }

    fn check(source: ?*c.GSource) callconv(.C) c.gboolean {
        const self = @fieldParentPtr(CommandSource, "source", source.?);
        self.cond = c.g_source_query_unix_fd(source, self.tag);
        return @boolToInt(self.cond != 0);
    }

    fn dispatch(source: ?*c.GSource, callback: c.GSourceFunc, user_data: c.gpointer) callconv(.C) c.gboolean {
        _ = callback;
        _ = user_data;

        const self = @fieldParentPtr(CommandSource, "source", source.?);
        if ((self.cond & c.G_IO_IN) != 0) {
            self.status_command.update() catch |err| {
                util.warn(@src(), "failed to update status command: {}", .{err});
            };
        } else if ((self.cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            return 0;
        }
        return 1;
    }

    var funcs = c.GSourceFuncs{
        .prepare = prepare,
        .check = check,
        .dispatch = dispatch,
        .finalize = null,
        .closure_callback = null,
        .closure_marshal = null,
    };
};

inline fn client(self: *StatusCommand) *Client {
    return @fieldParentPtr(Client, "status_command", self);
}
/// Spawn the process and return a GSource that tracks updates.
pub fn createSource(self: *StatusCommand) !*c.GSource {
    // spawn the process
    self.process = std.ChildProcess.init(&.{
        "/bin/sh", "-c", self.client().config.status_command,
    }, allocator);
    self.process.?.stdout_behavior = .Pipe;
    try self.process.?.spawn();
    self.process_running = true;
    // add the non-blocking flag so we can read without blocking
    const old_fl = try std.os.fcntl(self.process.?.stdout.?.handle, std.os.F.GETFL, 0);
    _ = try std.os.fcntl(self.process.?.stdout.?.handle, std.os.F.SETFL, old_fl | std.os.O.NONBLOCK);

    const source = c.g_source_new(&CommandSource.funcs, @sizeOf(CommandSource)).?;
    const command_source = @fieldParentPtr(CommandSource, "source", source);
    command_source.status_command = self;
    command_source.tag = c.g_source_add_unix_fd(source, self.process.?.stdout.?.handle, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP);

    return source;
}

pub fn deinit(self: *StatusCommand) void {
    if (self.process_running) {
        _ = self.process.?.kill() catch |err| {
            util.warn(@src(), "falied to kill status command: {}", .{err});
        };
    }
    self.status_buffer.deinit(allocator);
    allocator.free(self.status);
}

fn update(self: *StatusCommand) !void {
    while (true) {
        const byte = self.process.?.stdout.?.reader().readByte() catch |err| switch (err) {
            error.WouldBlock => return,
            else => |e| return e,
        };

        if (byte == '\n') {
            allocator.free(self.status);
            self.status = self.status_buffer.toOwnedSlice(allocator);
            self.client().updateGui();
        } else {
            try self.status_buffer.append(allocator, byte);
        }
    }
}
