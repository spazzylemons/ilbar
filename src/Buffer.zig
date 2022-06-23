const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Config = @import("Config.zig");
const Element = @import("Element.zig");
const IconManager = @import("IconManager.zig");
const PointerManager = @import("PointerManager.zig");
const std = @import("std");
const Toplevel = @import("Toplevel.zig");
const util = @import("util.zig");

const Buffer = @This();

memory: []align(std.mem.page_size) u8,
file: std.fs.File,

var counter: u8 = 0;

fn allocShm(size: usize) !std.fs.File {
    const name = try std.fmt.allocPrintZ(allocator, "/ilbar-shm-{}-{}", .{ std.os.linux.getpid(), counter });
    defer allocator.free(name);
    counter +%= 1;

    const fd = std.c.shm_open(name, std.os.O.RDWR | std.os.O.CREAT | std.os.O.EXCL, 0o600);
    if (fd < 0) {
        return switch (std.c.getErrno(fd)) {
            .ACCES => error.AccessDenied,
            .EXIST => error.PathAlreadyExists,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NFILE => error.SystemFdQuotaExceeded,
            else => error.UnexpectedError,
        };
    }
    _ = std.c.shm_unlink(name);
    const file = std.fs.File{ .handle = fd };
    errdefer file.close();

    try file.setEndPos(size);
    return file;
}

pub fn init(width: u32, height: u32) !Buffer {
    const new_size = try std.math.mul(u32, try std.math.mul(u32, width, height), 4);

    const file = try allocShm(new_size);
    errdefer file.close();

    const memory = try std.os.mmap(null, new_size, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED, file.handle, 0);
    errdefer std.os.munmap(memory);

    return Buffer{
        .memory = memory,
        .file = file,
    };
}

pub fn deinit(self: Buffer) void {
    self.file.close();
    std.os.munmap(self.memory);
}
