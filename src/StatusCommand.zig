const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");
const util = @import("util.zig");

const StatusCommand = @This();

status: []const u8 = &.{},
status_buffer: std.ArrayListUnmanaged(u8) = .{},
stdout: ?std.fs.File = null,
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
            util.warn(@src(), "cannot read status command", .{});
            // empty status command
            allocator.free(self.status_command.status);
            self.status_command.status = &.{};
            self.status_command.client().updateGui();
            // disconnect the GSource, preventing further updates
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

/// Spawn the command and return the file to read from.
fn spawnCommand(command: [*:0]const u8) !std.fs.File {
    // create a pipe
    const pipe = try std.os.pipe();
    // fork the process
    const pid = std.os.fork() catch |err| {
        std.os.close(pipe[0]);
        std.os.close(pipe[1]);
        return err;
    };
    // are we the child process?
    if (pid == 0) {
        // close the read end
        std.os.close(pipe[0]);
        // connect the write end to stdout
        std.os.dup2(pipe[1], std.os.STDOUT_FILENO) catch |err| {
            util.err(@src(), "status command: dup2 failed: {}", .{err});
            std.os.exit(1);
        };
        // and close the now unused write end
        std.os.close(pipe[1]);
        // GTK sets the SIGPIPE to SIG_IGN, which if we do not fix here, will cause a PID leak
        const act = std.os.Sigaction{
            .handler = .{ .sigaction = std.os.SIG.DFL },
            .mask = std.os.empty_sigset,
            .flags = 0,
        };
        std.os.sigaction(std.os.SIG.PIPE, &act, null) catch |err| {
            util.err(@src(), "status command: sigaction failed: {}", .{err});
            std.os.exit(1);
        };
        // execute the status command
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command, null };
        const err = std.os.execveZ("/bin/sh", &argv, std.c.environ);
        util.err(@src(), "status command: execv failed: {}", .{err});
        std.os.exit(1);
    }
    // close the read end on failure
    errdefer std.os.close(pipe[0]);
    // close the write end
    std.os.close(pipe[1]);
    // add the non-blocking flag so we can read without blocking
    const old_fl = try std.os.fcntl(pipe[0], std.os.F.GETFL, 0);
    _ = try std.os.fcntl(pipe[0], std.os.F.SETFL, old_fl | std.os.O.NONBLOCK);
    // return the read end of the pipe
    return std.fs.File{ .handle = pipe[0] };
}

/// Spawn the process and return a GSource that tracks updates.
pub fn createSource(self: *StatusCommand) !*c.GSource {
    self.stdout = try spawnCommand(self.client().config.status_command.ptr);

    const source = c.g_source_new(&CommandSource.funcs, @sizeOf(CommandSource)).?;
    const command_source = @fieldParentPtr(CommandSource, "source", source);
    command_source.status_command = self;
    command_source.tag = c.g_source_add_unix_fd(source, self.stdout.?.handle, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP);

    return source;
}

pub fn deinit(self: *StatusCommand) void {
    if (self.stdout) |stdout| stdout.close();
    self.status_buffer.deinit(allocator);
    allocator.free(self.status);
}

fn update(self: *StatusCommand) !void {
    while (true) {
        const byte = self.stdout.?.reader().readByte() catch |err| switch (err) {
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
