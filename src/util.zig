const c = @import("c.zig");
const std = @import("std");
extern fn strerror(c_int) [*:0]const u8;

fn stubFn(comptime T: type) T {
    const func = @typeInfo(T).Fn;
    return switch (func.args.len) {
        0 => struct {
            fn stub() callconv(.C) void {}
        },

        1 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
            ) callconv(.C) void {
                _ = a;
            }
        },

        2 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
            }
        },

        3 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
            }
        },

        4 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
                _ = d;
            }
        },

        5 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
                _ = d;
                _ = e;
            }
        },

        6 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
                _ = d;
                _ = e;
                _ = f;
            }
        },

        7 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
                g: func.args[6].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
                _ = d;
                _ = e;
                _ = f;
                _ = g;
            }
        },

        8 => struct {
            fn stub(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
                g: func.args[6].arg_type.?,
                h: func.args[7].arg_type.?,
            ) callconv(.C) void {
                _ = a;
                _ = b;
                _ = z;
                _ = d;
                _ = e;
                _ = f;
                _ = g;
                _ = h;
            }
        },

        else => @compileError("too many parameters to stub"),
    }.stub;
}

fn wrapFn(comptime T: type, comptime listener: anytype) T {
    const func = @typeInfo(T).Fn;
    const listener_func = @typeInfo(@TypeOf(listener)).Fn;

    const Tools = struct {
        fn castPtr(ptr: func.args[0].arg_type.?) listener_func.args[0].arg_type.? {
            return @ptrCast(
                listener_func.args[0].arg_type.?,
                @alignCast(@alignOf(@typeInfo(listener_func.args[0].arg_type.?).Pointer.child), ptr.?),
            );
        }
    };

    return switch (func.args.len) {
        0, 1 => @compileError("invalid event listener"),

        2 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b);
            }
        },

        3 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z);
            }
        },

        4 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z, d);
            }
        },

        5 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z, d, e);
            }
        },

        6 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z, d, e, f);
            }
        },

        7 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
                g: func.args[6].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z, d, e, f, g);
            }
        },

        8 => struct {
            fn wrap(
                a: func.args[0].arg_type.?,
                b: func.args[1].arg_type.?,
                z: func.args[2].arg_type.?,
                d: func.args[3].arg_type.?,
                e: func.args[4].arg_type.?,
                f: func.args[5].arg_type.?,
                g: func.args[6].arg_type.?,
                h: func.args[7].arg_type.?,
            ) callconv(.C) void {
                listener(Tools.castPtr(a), b, z, d, e, f, g, h);
            }
        },

        else => @compileError("too many parameters for event listener"),
    }.wrap;
}

pub fn createListener(comptime T: type, comptime F: type) T {
    var result: T = undefined;
    inline for (@typeInfo(T).Struct.fields) |field| {
        if (@hasDecl(F, field.name)) {
            @field(result, field.name) = wrapFn(@typeInfo(field.field_type).Optional.child, @field(F, field.name));
        } else {
            @field(result, field.name) = stubFn(@typeInfo(field.field_type).Optional.child);
        }
    }
    return result;
}

pub fn waylandError(loc: std.builtin.SourceLocation) error{WaylandError} {
    err(loc, "wayland error: {s}", .{strerror(@enumToInt(std.c.getErrno(-1)))});
    return error.WaylandError;
}

const labels = [_][]const u8{ "[INFO]", "[WARN]", "[ERROR]" };
const colors = [_][]const u8{ "\x1b[32m", "\x1b[33m", "\x1b[31m" };

const stderr = std.io.getStdErr().writer();

fn printHeader(level: u8, loc: std.builtin.SourceLocation) void {
    // print the time
    var buffer: ["00:00:00 ".len + 1]u8 = undefined;
    const time = c.time(null);
    if (c.localtime(&time)) |tm| {
        const size = c.strftime(&buffer, buffer.len, "%T ", tm);
        stderr.writeAll(buffer[0..size]) catch {};
    }
    // print the log level
    const color = stderr.context.supportsAnsiEscapeCodes();
    if (color) stderr.writeAll(colors[level]) catch {};
    stderr.writeAll(labels[level]) catch {};
    if (color) stderr.writeAll("\x1b[0m") catch {};
    // print the source location
    stderr.print(" {s}:{}: ", .{ loc.file, loc.line }) catch {};
}

fn log(level: u8, loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    printHeader(level, loc);
    if (@typeInfo(@TypeOf(args)).Struct.fields.len == 0) {
        // if the args field is empty, assume that we just want to print a string, to save on binary size
        stderr.writeAll(fmt ++ "\n") catch {};
    } else {
        stderr.print(fmt ++ "\n", args) catch {};
    }
}

pub fn info(loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    log(0, loc, fmt, args);
}

pub fn warn(loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    log(1, loc, fmt, args);
}

pub fn err(loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    log(2, loc, fmt, args);
}

fn findMaxBufSizeZ(comptime fmt: []const u8, comptime Args: type) u64 {
    var args: Args = undefined;
    inline for (@typeInfo(Args).Struct.fields) |field, i| {
        if (@typeInfo(field.field_type) != .Int) {
            // possible to implement for other types, but not needed as of now
            @compileError("unimplemented for type " ++ @typeName(field.field_type));
        }
        if (@typeInfo(field.field_type).Int.signedness == .signed) {
            args[i] = std.math.minInt(field.field_type);
        } else {
            args[i] = std.math.maxInt(field.field_type);
        }
    }
    return std.fmt.count(fmt, args) + 1;
}

pub fn arrayPrintZ(comptime fmt: []const u8, args: anytype) [findMaxBufSizeZ(fmt, @TypeOf(args))]u8 {
    var result: [findMaxBufSizeZ(fmt, @TypeOf(args))]u8 = undefined;
    _ = std.fmt.bufPrintZ(&result, fmt, args) catch unreachable;
    return result;
}
