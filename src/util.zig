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

pub fn waylandError() error{WaylandError} {
    std.log.err("wayland error: {s}", .{strerror(@enumToInt(std.c.getErrno(-1)))});
    return error.WaylandError;
}

pub fn gtkError(err: *c.GError) error{GtkError} {
    std.log.err("gtk error: {s}", .{err.message});
    c.g_error_free(err);
    return error.GtkError;
}
