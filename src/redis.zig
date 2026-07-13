const std = @import("std");

const Io = std.Io;

pub const Client = struct {
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    read_buf: [4096]u8,
    write_buf: [4096]u8,

    pub const ConnectError = Io.net.IpAddress.ConnectError || error{InvalidDsn};

    pub fn connect(io: Io, dsn: []const u8) ConnectError!Client {
        const host_port = try stripScheme(dsn);
        const addr = Io.net.IpAddress.parseLiteral(host_port) catch return error.InvalidDsn;
        var client: Client = undefined;
        client.io = io;
        client.stream = addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused, error.NetworkUnreachable, error.HostUnreachable, error.Timeout => return error.AddressUnavailable,
            else => return err,
        };
        client.reader = client.stream.reader(io, &client.read_buf);
        client.writer = client.stream.writer(io, &client.write_buf);
        return client;
    }

    pub fn close(self: *const Client) void {
        self.stream.close(self.io);
    }

    pub fn ping(self: *Client) ProtocolError![]const u8 {
        try writeCommand(&self.writer.interface, &.{"PING"});
        const reply = try readReply(&self.reader.interface);
        return switch (reply) {
            .simple => |s| s,
            .err => |msg| {
                std.log.warn("redis error: {s}", .{msg});
                return error.RedisError;
            },
            else => error.RedisProtocolError,
        };
    }

    /// SET key value EX ttl_seconds. Overwrites if exists.
    pub fn set(self: *Client, key: []const u8, value: []const u8, ttl_seconds: u32) ProtocolError!void {
        var ttl_buf: [16]u8 = undefined;
        const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_seconds}) catch unreachable;
        try writeCommand(&self.writer.interface, &.{ "SET", key, value, "EX", ttl_str });
        const reply = try readReply(&self.reader.interface);
        switch (reply) {
            .simple => |s| if (std.mem.eql(u8, s, "OK")) return,
            .err => |msg| {
                std.log.warn("redis error on SET: {s}", .{msg});
                return error.RedisError;
            },
            else => {},
        }
        return error.RedisProtocolError;
    }

    /// Returns the value bytes or null if key is missing.
    pub fn get(self: *Client, key: []const u8) ProtocolError!?[]const u8 {
        try writeCommand(&self.writer.interface, &.{ "GET", key });
        const reply = try readReply(&self.reader.interface);
        return switch (reply) {
            .bulk => |b| b,
            .err => |msg| {
                std.log.warn("redis error on GET: {s}", .{msg});
                return error.RedisError;
            },
            else => error.RedisProtocolError,
        };
    }

    /// Returns 1 if deleted, 0 if key did not exist.
    pub fn del(self: *Client, key: []const u8) ProtocolError!u32 {
        try writeCommand(&self.writer.interface, &.{ "DEL", key });
        const reply = try readReply(&self.reader.interface);
        return switch (reply) {
            .integer => |n| @intCast(@as(i64, @intCast(n))),
            .err => |msg| {
                std.log.warn("redis error on DEL: {s}", .{msg});
                return error.RedisError;
            },
            else => error.RedisProtocolError,
        };
    }
};

pub const ProtocolError = Io.Reader.Error || Io.Writer.Error || error{
    RedisProtocolError,
    RedisError,
    StreamTooLong,
};

const Reply = union(enum) {
    simple: []const u8,
    err: []const u8,
    integer: i64,
    bulk: ?[]const u8,
};

/// Write a RESP2 array command. `parts` become the array elements.
fn writeCommand(w: *Io.Writer, parts: []const []const u8) ProtocolError!void {
    try w.print("*{d}\r\n", .{parts.len});
    for (parts) |part| {
        try w.print("${d}\r\n{s}\r\n", .{ part.len, part });
    }
    try w.flush();
}

fn readReply(r: *Io.Reader) ProtocolError!Reply {
    var type_buf: [1]u8 = undefined;
    try r.readSliceAll(&type_buf);
    const prefix = type_buf[0];

    switch (prefix) {
        '+' => {
            const line = (try r.takeDelimiter('\n')) orelse return error.RedisProtocolError;
            return .{ .simple = stripCr(line) };
        },
        '-' => {
            const line = (try r.takeDelimiter('\n')) orelse return error.RedisProtocolError;
            return .{ .err = stripCr(line) };
        },
        ':' => {
            const line = (try r.takeDelimiter('\n')) orelse return error.RedisProtocolError;
            const n = std.fmt.parseInt(i64, stripCr(line), 10) catch return error.RedisProtocolError;
            return .{ .integer = n };
        },
        '$' => {
            const len_line = (try r.takeDelimiter('\n')) orelse return error.RedisProtocolError;
            const len = std.fmt.parseInt(isize, stripCr(len_line), 10) catch return error.RedisProtocolError;
            if (len < 0) return .{ .bulk = null };
            const data = try r.take(@intCast(len));
            var crlf: [2]u8 = undefined;
            try r.readSliceAll(&crlf);
            if (crlf[0] != '\r' or crlf[1] != '\n') return error.RedisProtocolError;
            return .{ .bulk = data };
        },
        '*' => return error.RedisProtocolError,
        else => return error.RedisProtocolError,
    }
}

fn stripCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

/// Strip optional redis:// scheme and trailing /db. Returns the host:port portion.
fn stripScheme(dsn: []const u8) error{InvalidDsn}![]const u8 {
    var rest: []const u8 = dsn;
    if (std.mem.startsWith(u8, rest, "redis://")) {
        rest = rest["redis://".len..];
    }
    if (std.mem.findScalar(u8, rest, '@')) |at| {
        rest = rest[at + 1 ..];
    }
    if (std.mem.findScalar(u8, rest, '/')) |slash| {
        if (slash + 1 < rest.len) {
            for (rest[slash + 1 ..]) |c| if (c < '0' or c > '9') return error.InvalidDsn;
        }
        rest = rest[0..slash];
    }
    if (rest.len == 0) return error.InvalidDsn;
    return rest;
}

test "stripScheme basic" {
    try std.testing.expectEqualStrings("localhost:6379", try stripScheme("redis://localhost:6379"));
    try std.testing.expectEqualStrings("localhost:6379", try stripScheme("localhost:6379"));
    try std.testing.expectEqualStrings("localhost:6379", try stripScheme("redis://localhost:6379/0"));
    try std.testing.expectEqualStrings("localhost:6379", try stripScheme("redis://user:pass@localhost:6379/0"));
    try std.testing.expectError(error.InvalidDsn, stripScheme("redis://"));
    try std.testing.expectError(error.InvalidDsn, stripScheme("redis://localhost:6379/abc"));
}

test "integration: PING/SET/GET/DEL round-trip" {
    var client = Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer client.close();

    const pong = try client.ping();
    try std.testing.expectEqualStrings("PONG", pong);

    const key = "zicada-test-round-trip";
    try client.set(key, "hello", 60);
    const got = try client.get(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("hello", got.?);

    const deleted = try client.del(key);
    try std.testing.expectEqual(@as(u32, 1), deleted);
    const after = try client.get(key);
    try std.testing.expect(after == null);

    const missing_del = try client.del(key);
    try std.testing.expectEqual(@as(u32, 0), missing_del);
}

test "integration: SET with EX is stored with TTL" {
    var client = Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer client.close();

    const key = "zicada-test-ttl";
    try client.set(key, "v", 60);
    const got = try client.get(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expectEqual(@as(u32, 1), try client.del(key));
}

test "integration: connect failures" {
    try std.testing.expectError(error.InvalidDsn, Client.connect(std.testing.io, "not-a-dsn"));
    try std.testing.expectError(error.AddressUnavailable, Client.connect(std.testing.io, "127.0.0.1:1"));
}