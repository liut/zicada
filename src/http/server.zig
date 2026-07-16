const std = @import("std");
const redis = @import("../redis.zig");
const util = @import("../util.zig");

const Io = std.Io;
const Http = std.http;

const MAX_BODY_BYTES: usize = 1024 * 1024;
/// RR TTL written into zone-text A records; matches server-side defaults.
const RECORD_TTL: u32 = 60;
const RECORD_DAYS: u32 = 7;
const SECONDS_PER_DAY: u32 = 24 * 60 * 60;

/// What we'll deserialize from the request body. `ignore_unknown_fields` is
/// set so we can evolve the schema without breaking old clients.
const Record = struct {
    name: []const u8,
    ip: []const u8,
};

/// Bind TCP on `port+1` and serve the small DNS HTTP API until `shutdown`
/// is set. Each accepted connection is handled inline (one-at-a-time);
/// concurrent requests are not supported in v1.
pub fn runServer(
    io: Io,
    port: u16,
    dsn: []const u8,
    shutdown: *const std.atomic.Value(bool),
) !void {
    const http_port = port + 1;
    var bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(http_port) };
    var listener = bind_addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch |err| {
        std.log.err("http listen failed on port {d}: {s}", .{ http_port, @errorName(err) });
        return err;
    };
    defer listener.deinit(io);

    var client = redis.Client.connect(io, dsn) catch |err| {
        std.log.err("redis connect failed: {s}", .{@errorName(err)});
        return err;
    };
    defer client.close();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (!shutdown.load(.monotonic)) {
        const stream = listener.accept(io) catch |err| {
            std.log.warn("http accept failed: {s}", .{@errorName(err)});
            continue;
        };
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();
        handleConnection(io, stream, &client, allocator) catch |err| {
            std.log.warn("http connection error: {s}", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn handleConnection(
    io: Io,
    stream: Io.net.Stream,
    client: *redis.Client,
    allocator: std.mem.Allocator,
) !void {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var body_buf: [MAX_BODY_BYTES]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var server = Http.Server.init(&reader.interface, &writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpHeadersInvalid, error.HttpHeadersOversize => return,
        else => return err,
    };

    const is_a_path = std.mem.eql(u8, request.head.target, "/api/dns/a");
    const method = request.head.method;

    if (is_a_path and (method == .GET or method == .HEAD)) {
        try request.respond("", .{
            .status = .no_content,
            .transfer_encoding = .none,
        });
        return;
    }

    if (is_a_path and method == .PUT) {
        try handlePutDnsA(&request, client, &body_buf, allocator);
        return;
    }

    try request.respond("bad request", .{
        .status = .bad_request,
        .transfer_encoding = .chunked,
    });
}

fn handlePutDnsA(
    request: *Http.Server.Request,
    client: *redis.Client,
    body_buf: []u8,
    allocator: std.mem.Allocator,
) !void {
    const content_length = request.head.content_length orelse 0;
    if (content_length == 0) {
        return request.respond("ok\n", .{ .status = .ok, .transfer_encoding = .chunked });
    }
    if (content_length > body_buf.len) {
        return request.respond("body too large", .{
            .status = .payload_too_large,
            .transfer_encoding = .chunked,
        });
    }

    // bodyReader needs its own scratch for the underlying socket reads; using
    // body_buf for both would alias the target passed to readSliceShort.
    var scratch: [4096]u8 = undefined;
    const body_reader = request.server.reader.bodyReader(
        &scratch,
        request.head.transfer_encoding,
        request.head.content_length,
    );

    var read: usize = 0;
    while (read < content_length) {
        const want = content_length - read;
        const n = body_reader.readSliceShort(body_buf[read..][0..want]) catch |err| return err;
        if (n == 0) break; // peer closed before content_length
        read += n;
    }
    if (read != content_length) {
        return request.respond("short body", .{
            .status = .bad_request,
            .transfer_encoding = .chunked,
        });
    }

    const parsed = std.json.parseFromSlice([]Record, allocator, body_buf[0..read], .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const msg = @errorName(err);
        return request.respond(msg, .{
            .status = .bad_request,
            .transfer_encoding = .chunked,
        });
    };
    defer parsed.deinit();

    for (parsed.value) |rec| {
        applyRecord(rec, client, allocator) catch |err| {
            std.log.info("skipping record name={s} ip={s} err={s}", .{ rec.name, rec.ip, @errorName(err) });
            continue;
        };
    }

    try request.respond("ok\n", .{ .status = .ok, .transfer_encoding = .chunked });
}

fn applyRecord(rec: Record, client: *redis.Client, allocator: std.mem.Allocator) !void {
    const lower_name = try util.lower(allocator, rec.name);
    defer allocator.free(lower_name);
    const key = try std.fmt.allocPrint(allocator, "dns-a-{s}", .{lower_name});
    defer allocator.free(key);
    const ip = try util.parseIPv4(rec.ip);
    const value = try util.formatA(allocator, rec.name, RECORD_TTL, ip);
    defer allocator.free(value);
    try client.set(key, value, RECORD_DAYS * SECONDS_PER_DAY);
}

// ---------------------------------------------------------------------------
// Tests (unit-level JSON parsing + record application; integration tests
// that drive a real server with curl live in scripts/smoke.sh).
// ---------------------------------------------------------------------------

test "applyRecord writes zone-text A to Redis" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();

    const key = "dns-a-http-test.example.com";
    defer { _ = rc.del(key) catch {}; }

    const rec = Record{ .name = "http-test.example.com", .ip = "10.0.0.42" };
    try applyRecord(rec, &rc, std.testing.allocator);

    const got = try rc.get(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("http-test.example.com. 60 IN A 10.0.0.42", got.?);
}

test "applyRecord rejects malformed IP without writing" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();
    const rec = Record{ .name = "bad-ip.example.com", .ip = "not.an.ip" };
    try std.testing.expectError(error.InvalidIp, applyRecord(rec, &rc, std.testing.allocator));
    const after = try rc.get("dns-a-bad-ip.example.com");
    try std.testing.expect(after == null);
}

test "json parseFromSlice accepts batch and ignores unknown fields" {
    const body =
        \\[{"name":"a.example.com","ip":"10.0.0.1","extra":"ignored"},
        \\ {"name":"b.example.com","ip":"10.0.0.2"}]
    ;
    const parsed = try std.json.parseFromSlice([]Record, std.testing.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
    try std.testing.expectEqualStrings("a.example.com", parsed.value[0].name);
    try std.testing.expectEqualStrings("10.0.0.2", parsed.value[1].ip);
}

test "json parseFromSlice accepts empty array" {
    const parsed = try std.json.parseFromSlice([]Record, std.testing.allocator, "[]", .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.len);
}

test "integration: PUT /api/dns/a applies batch and returns ok" {
    // Pre-clean any stale keys we touch.
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();
    const keys = [_][]const u8{
        "dns-a-http-batch-a.example.com",
        "dns-a-http-batch-b.example.com",
    };
    inline for (keys) |k| _ = rc.del(k) catch {};
    defer inline for (keys) |k| { _ = rc.del(k) catch {}; };

    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13553;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port - 1, "redis://127.0.0.1:6379", &shutdown,
    });
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        // runServer blocks in listener.accept() without a timeout, so we can't
        // join — detach and let the OS reap the thread at process exit.
        shutdown.store(true, .monotonic);
        thread.detach();
    }

    // Build a TCP client connection manually so we don't depend on std.http.Client.
    var dst_addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var dst = dst_addr.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp }) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    defer dst.close(std.testing.io);

    const body =
        \\[{"name":"http-batch-a.example.com","ip":"10.99.0.1"},
        \\ {"name":"http-batch-b.example.com","ip":"10.99.0.2"}]
    ;
    var write_buf: [4096]u8 = undefined;
    var w = dst.writer(std.testing.io, &write_buf);
    try w.interface.print(
        "PUT /api/dns/a HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try w.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var r = dst.reader(std.testing.io, &read_buf);
    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(std.testing.allocator);
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(std.testing.allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "ok\n") != null);

    // Verify Redis writes happened.
    const a = try rc.get("dns-a-http-batch-a.example.com");
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("http-batch-a.example.com. 60 IN A 10.99.0.1", a.?);
    const b = try rc.get("dns-a-http-batch-b.example.com");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("http-batch-b.example.com. 60 IN A 10.99.0.2", b.?);
}

test "integration: PUT batch skips malformed records and commits the rest" {
    // Drives the documented skip-and-continue path: a bad record sitting
    // between two good ones must not abort the batch, and the response
    // must still be 200 ok. The bad record's Redis key must NOT appear.
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();
    const keys = [_][]const u8{
        "dns-a-http-batch-skip-1.example.com",
        "dns-a-http-batch-skip-bad.example.com",
        "dns-a-http-batch-skip-2.example.com",
    };
    inline for (keys) |k| _ = rc.del(k) catch {};
    defer inline for (keys) |k| { _ = rc.del(k) catch {}; };

    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13556;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port - 1, "redis://127.0.0.1:6379", &shutdown,
    });
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        shutdown.store(true, .monotonic);
        thread.detach();
    }

    var dst_addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var dst = dst_addr.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp }) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    defer dst.close(std.testing.io);

    // Middle record carries a malformed IPv4 ("not-an-ip"); it's the one
    // that must be skipped. The two records around it must still commit.
    const body =
        \\[{"name":"http-batch-skip-1.example.com","ip":"10.99.1.1"},
        \\ {"name":"http-batch-skip-bad.example.com","ip":"not-an-ip"},
        \\ {"name":"http-batch-skip-2.example.com","ip":"10.99.1.2"}]
    ;
    var write_buf: [4096]u8 = undefined;
    var w = dst.writer(std.testing.io, &write_buf);
    try w.interface.print(
        "PUT /api/dns/a HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try w.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var r = dst.reader(std.testing.io, &read_buf);
    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(std.testing.allocator);
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(std.testing.allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "ok\n") != null);

    // Good #1 must be present, with the correct zone-text value.
    const a = try rc.get("dns-a-http-batch-skip-1.example.com");
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("http-batch-skip-1.example.com. 60 IN A 10.99.1.1", a.?);
    // Bad record must not have created a key.
    const bad = try rc.get("dns-a-http-batch-skip-bad.example.com");
    try std.testing.expect(bad == null);
    // Good #2 (after the bad one) must also be present.
    const b = try rc.get("dns-a-http-batch-skip-2.example.com");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("http-batch-skip-2.example.com. 60 IN A 10.99.1.2", b.?);
}

test "integration: GET /api/dns/a returns 204" {
    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13554;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port - 1, "redis://127.0.0.1:6379", &shutdown,
    });
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        shutdown.store(true, .monotonic);
        thread.detach();
    }

    var dst_addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var dst = dst_addr.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp }) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    defer dst.close(std.testing.io);

    var write_buf: [4096]u8 = undefined;
    var w = dst.writer(std.testing.io, &write_buf);
    try w.interface.print("GET /api/dns/a HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{});
    try w.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var r = dst.reader(std.testing.io, &read_buf);
    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(std.testing.allocator);
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(std.testing.allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "204") != null);
}

test "integration: PUT /wrong returns 400" {
    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13555;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port - 1, "redis://127.0.0.1:6379", &shutdown,
    });
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        shutdown.store(true, .monotonic);
        thread.detach();
    }

    var dst_addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var dst = dst_addr.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp }) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    defer dst.close(std.testing.io);

    var write_buf: [4096]u8 = undefined;
    var w = dst.writer(std.testing.io, &write_buf);
    try w.interface.print("PUT /wrong HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
    try w.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var r = dst.reader(std.testing.io, &read_buf);
    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(std.testing.allocator);
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response_buf.appendSlice(std.testing.allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, response_buf.items, "\r\n\r\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, response_buf.items, "400") != null);
}
