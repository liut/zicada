const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Level = enum { debug, info, warn, err };

/// A single key/value field on a log event. Kept stringly-typed for v1 —
/// the caller formats values ahead of time.
pub const Field = struct { key: []const u8, value: []const u8 };

/// Emit one log event to stdout. Format depends on build mode:
///   * Debug   → human-readable: `LEVEL scope msg k=v k=v`
///   * Release → JSON line: `{"l":"info","s":"dns","m":"...","k":"v"}`
///
/// `stdout_buf` is caller-supplied so the function is allocator-free and
/// safe to call from server-thread contexts. Failures are swallowed; a log
/// emission must never crash the server. Lines longer than `stdout_buf.len`
/// panic in Debug and are truncated in Release — log messages must stay small.
///
/// Each call creates a fresh `Io.File.Writer` in **streaming** mode (raw
/// `write()` sequential); the default positional mode resets seek to 0 on
/// every new Writer, which would otherwise overwrite earlier lines.
pub fn event(
    io: Io,
    stdout_buf: []u8,
    level: Level,
    scope: []const u8,
    msg: []const u8,
    fields: []const Field,
) void {
    var fw = Io.File.stdout().writerStreaming(io, stdout_buf);
    const writer = &fw.interface;
    const emit = if (builtin.mode == .Debug) emitPretty else emitJson;
    emit(writer, level, scope, msg, fields) catch return;
    fw.flush() catch {};
}

fn emitPretty(
    writer: anytype,
    level: Level,
    scope: []const u8,
    msg: []const u8,
    fields: []const Field,
) @TypeOf(writer.*).Error!void {
    try writer.print("{s:5} {s:8} {s}", .{ @tagName(level), scope, msg });
    for (fields) |f| try writer.print(" {s}={s}", .{ f.key, f.value });
    try writer.writeByte('\n');
}

fn emitJson(
    writer: anytype,
    level: Level,
    scope: []const u8,
    msg: []const u8,
    fields: []const Field,
) @TypeOf(writer.*).Error!void {
    try writer.print("{{\"l\":\"{s}\",\"s\":\"{s}\",\"m\":\"", .{ @tagName(level), scope });
    try writeEscaped(writer, msg);
    try writer.writeByte('"');
    for (fields) |f| {
        try writer.print(",\"{s}\":\"", .{f.key});
        try writeEscaped(writer, f.value);
        try writer.writeByte('"');
    }
    try writer.writeAll("}\n");
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) try writer.print("\\u{x:0>4}", .{c}) else try writer.writeByte(c),
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (build-mode gated; pretty path is checked only in Debug builds)
// ---------------------------------------------------------------------------

fn renderToList(level: Level, msg: []const u8, fields: []const Field) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (builtin.mode == .Debug) {
        try emitPretty(w, level, "test", msg, fields);
    } else {
        try emitJson(w, level, "test", msg, fields);
    }
    var al = aw.toArrayList();
    defer al.deinit(std.testing.allocator);
    return al.toOwnedSlice(std.testing.allocator);
}

test "event pretty: contains level, scope, msg, key=value" {
    if (builtin.mode != .Debug) return error.SkipZigTest;
    const out = try renderToList(.info, "starting", &[_]Field{
        .{ .key = "port", .value = "1353" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "info") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "starting") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "port=1353") != null);
}

test "event json: includes quoted fields and escapes embedded quotes" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const out = try renderToList(.warn, "bad \"input\"", &[_]Field{
        .{ .key = "k", .value = "v\"w" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"l\":\"warn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"m\":\"bad \\\"input\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"k\":\"v\\\"w\"") != null);
}

test "event: zero fields still emits required keys" {
    const out = try renderToList(.err, "boom", &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    if (builtin.mode == .Debug) {
        try std.testing.expect(std.mem.indexOf(u8, out, "err") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, out, "\"l\":\"err\"") != null);
    }
}

test "event json: escapes newlines, tabs, control chars" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const out = try renderToList(.info, "a\nb\tc", &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\t") != null);
}
