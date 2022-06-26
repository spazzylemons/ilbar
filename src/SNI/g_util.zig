const c = @import("../c.zig");

pub inline fn cast(comptime T: type, value: anytype, ty: c.GType) *T {
    if (@typeInfo(T) == .Opaque) {
        return @ptrCast(*T, c.g_type_check_instance_cast(@ptrCast(*c.GTypeInstance, @alignCast(@alignOf(c.GTypeInstance), value)), ty));
    } else {
        return @ptrCast(*T, @alignCast(@alignOf(T), c.g_type_check_instance_cast(@ptrCast(*c.GTypeInstance, @alignCast(@alignOf(c.GTypeInstance), value)), ty)));
    }
}

pub inline fn signalConnect(instance: anytype, detailed_signal: anytype, c_handler: anytype, data: anytype) c.gulong {
    return c.g_signal_connect_data(instance, detailed_signal, c_handler, data, null, 0);
}

pub inline fn callback(value: anytype) c.GCallback {
    return @intToPtr(c.GCallback, @ptrToInt(value));
}

pub inline fn dbusError(invocation: *c.GDBusMethodInvocation, err: c_int, message: [*:0]const u8) void {
    c.g_dbus_method_invocation_return_error(
        invocation,
        c.g_dbus_error_quark(),
        err,
        message,
    );
}

pub inline fn dbusOom(invocation: *c.GDBusMethodInvocation, message: [*:0]const u8) void {
    dbusError(
        invocation,
        c.G_DBUS_ERROR_NO_MEMORY,
        message,
    );
}
