const std = @import("std");
const redis = @import("../redis.zig");
const util = @import("../util.zig");
const wire = @import("wire.zig");
const update = @import("update.zig");

const Io = std.Io;

/// Maximum DNS UDP datagram size (RFC 1035 §4.2.1).
pub const MAX_DATAGRAM: usize = 512;
/// Idle wake period between receives; also the upper bound on how long
/// it takes `runServer` to notice a shutdown flag flip (kept short so
/// SIGINT/SIGTERM in main.zig observes within ~1s).
pub const RECV_TIMEOUT_NS: u64 = 500 * std.time.ns_per_ms;

/// Block on the configured UDP port and dispatch each datagram until `shutdown`
/// is set. `dsn` is the Redis URL used to answer A queries. The loop polls
/// shutdown between receives (capped at 5s) so SIGINT/SIGTERM is observed
/// without delay while idle.
pub fn runServer(
    io: Io,
    port: u16,
    dsn: []const u8,
    shutdown: *const std.atomic.Value(bool),
) !void {
    var bind_addr: Io.net.IpAddress = .{ .ip4 = .unspecified(port) };
    var socket = bind_addr.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    }) catch |err| {
        std.log.err("dns bind failed on port {d}: {s}", .{ port, @errorName(err) });
        return err;
    };
    defer socket.close(io);

    var client = redis.Client.connect(io, dsn) catch |err| {
        std.log.err("redis connect failed: {s}", .{@errorName(err)});
        return err;
    };
    defer client.close();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var recv_buf: [MAX_DATAGRAM]u8 = undefined;
    var send_buf: [MAX_DATAGRAM]u8 = undefined;
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = RECV_TIMEOUT_NS },
        .clock = .real,
    } };

    while (!shutdown.load(.monotonic)) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        const recv = socket.receiveTimeout(io, &recv_buf, timeout) catch |err| switch (err) {
            error.Timeout => continue,
            else => {
                std.log.warn("dns receive error: {s}", .{@errorName(err)});
                return err;
            },
        };
        if (recv.flags.trunc) continue;
        if (recv.data.len < 12 or recv.data.len > MAX_DATAGRAM) continue;
        handleDatagram(io, &socket, &client, recv, &send_buf, allocator);
    }
}

fn handleDatagram(
    io: Io,
    socket: *const Io.net.Socket,
    client: *redis.Client,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    allocator: std.mem.Allocator,
) void {
    var query = wire.decodeQuery(recv.data, allocator) catch |err| switch (err) {
        error.InvalidQueryHeader => return sendErrorResponse(io, socket, recv, send_buf, .formerr),
        error.OpcodeNotImplemented => return sendErrorResponse(io, socket, recv, send_buf, .notimp),
        else => return,
    };
    defer query.deinit(allocator);

    if (query.header.ancount > 1 or query.header.nscount > 1 or query.header.arcount > 2) return;

    switch (query.header.flags.opcode) {
        0, 4 => handleQuery(io, socket, client, recv, send_buf, &query, allocator),
        5 => update.handle(io, socket, recv, send_buf, recv.data, client, allocator),
        else => {},
    }
}

fn handleQuery(
    io: Io,
    socket: *const Io.net.Socket,
    client: *redis.Client,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    query: *const wire.Message,
    allocator: std.mem.Allocator,
) void {
    const qtype = query.question.?.qtype;
    if (qtype != 1) {
        sendNoDataResponse(io, socket, recv, send_buf, query);
        return;
    }

    const name_lower = util.lower(allocator, query.question.?.name) catch return;
    defer allocator.free(name_lower);
    const key = std.fmt.allocPrint(allocator, "dns-a-{s}", .{name_lower}) catch return;
    defer allocator.free(key);

    const value = client.get(key) catch |err| {
        std.log.warn("redis get failed: {s}", .{@errorName(err)});
        sendErrorResponse(io, socket, recv, send_buf, .servfail);
        return;
    };

    if (value == null) {
        sendErrorResponse(io, socket, recv, send_buf, .nxdomain);
        return;
    }

    const parsed = parseZoneTextA(value.?) catch {
        std.log.warn("malformed zone-text: {s}", .{value.?});
        sendErrorResponse(io, socket, recv, send_buf, .servfail);
        return;
    };

    const n = buildResponse(send_buf, query, .noerror, parsed.ip, parsed.ttl) catch return;
    socket.send(io, &recv.from, send_buf[0..n]) catch |err| {
        std.log.warn("dns send error: {s}", .{@errorName(err)});
    };
}

/// Placeholder for the U6 nsupdate UPDATE handler. Replies NOERROR with no
/// answer records so the server can be exercised end-to-end before U6 lands.
fn handleUpdateStub(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    query: *const wire.Message,
) void {
    const n = buildResponse(send_buf, query, .noerror, null, 0) catch return;
    socket.send(io, &recv.from, send_buf[0..n]) catch |err| {
        std.log.warn("dns send error: {s}", .{@errorName(err)});
    };
}

fn sendErrorResponse(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    rcode: wire.Rcode,
) void {
    const header = wire.Header.decode(recv.data) catch return;
    const msg: wire.Message = .{
        .header = .{
            .id = header.id,
            .flags = .{
                .qr = 1,
                .opcode = header.flags.opcode,
                .aa = 0,
                .tc = 0,
                .rd = header.flags.rd,
                .ra = 1,
                .z = 0,
                .rcode = @intFromEnum(rcode),
            },
            .qdcount = 0,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
    };
    const n = wire.encodeMessage(send_buf, msg) catch return;
    socket.send(io, &recv.from, send_buf[0..n]) catch |err| {
        std.log.warn("dns send error: {s}", .{@errorName(err)});
    };
}

fn sendNoDataResponse(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    query: *const wire.Message,
) void {
    const n = buildResponse(send_buf, query, .noerror, null, 0) catch return;
    socket.send(io, &recv.from, send_buf[0..n]) catch |err| {
        std.log.warn("dns send error: {s}", .{@errorName(err)});
    };
}

/// Build a response from a query + outcome. Caller supplies the output buffer;
/// the encoded length is returned. `answer_ip == null` yields an empty answer
/// section (NOERROR/NXDOMAIN/NOTIMP shape). The answer's name is unused on
/// the wire (we always emit the 0xC0 0x0C back-pointer) but we still need
/// the field to satisfy the wire codec — we point it at the question's
/// name for symmetry and rely on the caller not to call deinit().
pub fn buildResponse(
    send_buf: []u8,
    query: *const wire.Message,
    rcode: wire.Rcode,
    answer_ip: ?[4]u8,
    answer_ttl: u32,
) !usize {
    var msg: wire.Message = .{
        .header = .{
            .id = query.header.id,
            .flags = .{
                .qr = 1,
                .opcode = query.header.flags.opcode,
                .aa = 0,
                .tc = 0,
                .rd = query.header.flags.rd,
                .ra = 1,
                .z = 0,
                .rcode = @intFromEnum(rcode),
            },
            .qdcount = query.header.qdcount,
            .ancount = if (answer_ip != null) 1 else 0,
            .nscount = 0,
            .arcount = 0,
        },
    };
    if (query.question) |q| {
        msg.question = .{
            .name = q.name,
            .qtype = q.qtype,
            .qclass = q.qclass,
        };
    }
    if (answer_ip) |ip| {
        const q_name = if (msg.question) |q| q.name else &[_]u8{};
        msg.answer = .{
            .name = @constCast(q_name),
            .rrtype = 1,
            .rrclass = 1,
            .ttl = answer_ttl,
            .rdata = &ip,
        };
    }
    return wire.encodeMessage(send_buf, msg);
}

pub const ZoneTextA = struct {
    ttl: u32,
    ip: [4]u8,
};

/// Parse a zone-text A record (`"name. ttl IN A a.b.c.d"`) emitted by
/// `util.formatA` and stored in Redis. Returns an error if the shape deviates
/// from the layout we wrote — Redis is the only source, so a mismatch means
/// the writer is broken, not the reader.
pub fn parseZoneTextA(value: []const u8) !ZoneTextA {
    var it = std.mem.splitScalar(u8, value, ' ');
    _ = it.next() orelse return error.InvalidZoneText;
    const ttl_str = it.next() orelse return error.InvalidZoneText;
    const ttl = std.fmt.parseInt(u32, ttl_str, 10) catch return error.InvalidZoneText;
    const in_str = it.next() orelse return error.InvalidZoneText;
    if (!std.mem.eql(u8, in_str, "IN")) return error.InvalidZoneText;
    const a_str = it.next() orelse return error.InvalidZoneText;
    if (!std.mem.eql(u8, a_str, "A")) return error.InvalidZoneText;
    const ip_str = it.next() orelse return error.InvalidZoneText;
    const ip = try util.parseIPv4(ip_str);
    return .{ .ttl = ttl, .ip = ip.bytes };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseZoneTextA extracts ttl and ip" {
    const z = try parseZoneTextA("app.example.com. 60 IN A 10.0.0.1");
    try std.testing.expectEqual(@as(u32, 60), z.ttl);
    try std.testing.expectEqual([_]u8{ 10, 0, 0, 1 }, z.ip);
}

test "parseZoneTextA round-trips with formatA" {
    const ip = try util.parseIPv4("192.168.1.42");
    const text = try util.formatA(std.testing.allocator, "host.example.com", 30, ip);
    defer std.testing.allocator.free(text);
    const z = try parseZoneTextA(text);
    try std.testing.expectEqual(@as(u32, 30), z.ttl);
    try std.testing.expectEqual([_]u8{ 192, 168, 1, 42 }, z.ip);
}

test "parseZoneTextA rejects malformed input" {
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA(""));
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA("name"));
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA("name. ttl"));
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA("name. abc IN A 1.2.3.4"));
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA("name. 60 CLASS A 1.2.3.4"));
    try std.testing.expectError(error.InvalidZoneText, parseZoneTextA("name. 60 IN MX 1.2.3.4"));
    try std.testing.expectError(error.InvalidIp, parseZoneTextA("name. 60 IN A not-an-ip"));
}

test "buildResponse: NXDOMAIN echoes question, ANCOUNT=0" {
    const query_bytes = [_]u8{
        0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    var query = try wire.decodeQuery(&query_bytes, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    var buf: [512]u8 = undefined;
    const n = try buildResponse(&buf, &query, .nxdomain, null, 0);
    // Expected: ID echoed, FLAGS = 0x81 0x83 (QR=1, RD=1, RA=1, RCODE=3),
    // QDCOUNT=1, ANCOUNT=0, then the question section.
    const expected = [_]u8{
        0xAB, 0xCD, 0x81, 0x83, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "buildResponse: NOERROR with A answer uses 0xC0 0x0C back-pointer" {
    const query_bytes = [_]u8{
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    var query = try wire.decodeQuery(&query_bytes, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    var buf: [512]u8 = undefined;
    const n = try buildResponse(&buf, &query, .noerror, .{ 10, 0, 0, 1 }, 60);
    // Expected: ID echoed, FLAGS = 0x81 0x80 (QR=1, RD=1, RA=1, RCODE=0),
    // QDCOUNT=1, ANCOUNT=1, then question + answer with 0xC0 0x0C back-pointer.
    const expected = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 0x0A, 0x00, 0x00, 0x01,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "buildResponse: NOERROR without answer for AAAA query" {
    const query_bytes = [_]u8{
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00,
        0x00, 0x1C, 0x00, 0x01, // QTYPE=AAAA
    };
    var query = try wire.decodeQuery(&query_bytes, std.testing.allocator);
    defer query.deinit(std.testing.allocator);

    var buf: [512]u8 = undefined;
    const n = try buildResponse(&buf, &query, .noerror, null, 0);
    const expected = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00, 0x00, 0x1C, 0x00, 0x01,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "buildResponse: FORMERR for error path" {
    // Build a synthetic message that wire.Header.decode can read, but where
    // the question is truncated so we can't include it in the response.
    const bytes = [_]u8{
        0x12, 0x34, 0x80, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // QR=1
        0x03, 'a',
    };
    // Confirm decodeQuery rejects this (it would be a QR=1 query)
    try std.testing.expectError(error.InvalidQueryHeader, wire.decodeQuery(&bytes, std.testing.allocator));
    // We can still extract the header for an error response
    const header = try wire.Header.decode(&bytes);
    try std.testing.expectEqual(@as(u16, 0x1234), header.id);
    try std.testing.expectEqual(@as(u1, 1), header.flags.qr);
}

test "buildResponse: NOTIMP echoes RCODE=4 in response flags" {
    var query: wire.Message = .{
        .header = .{
            .id = 0x4242,
            .flags = .{ .qr = 0, .opcode = 0, .aa = 0, .tc = 0, .rd = 0, .ra = 0, .z = 0, .rcode = 0 },
            .qdcount = 0,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
    };
    var buf: [512]u8 = undefined;
    const n = try buildResponse(&buf, &query, .notimp, null, 0);
    // FLAGS byte 0: QR=1, RD=0 = 0x80. byte 1: RA=1, RCODE=4 = 0x84.
    const expected = [_]u8{
        0x42, 0x42, 0x80, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "integration: server answers A query end-to-end" {
    // Pre-populate Redis with a known record
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();
    const key = "dns-a-zicada-int-test";
    try rc.set(key, "zicada-int-test. 60 IN A 10.0.0.99", 60);
    defer { _ = rc.del(key) catch {}; }

    // Start server in a thread on an ephemeral port range
    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13531;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port, "redis://127.0.0.1:6379", &shutdown,
    });
    // Give the bind a moment, but don't sleep too long — the bind is synchronous
    // so a small delay is enough to let the OS settle.
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        shutdown.store(true, .monotonic);
        thread.join();
    }

    // Build an A query for the test name
    var query_buf: [256]u8 = undefined;
    const query_msg: wire.Message = .{
        .header = .{
            .id = 0x1234,
            .flags = .{ .qr = 0, .opcode = 0, .aa = 0, .tc = 0, .rd = 1, .ra = 0, .z = 0, .rcode = 0 },
            .qdcount = 1,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
        .question = .{
            .name = try std.testing.allocator.dupe(u8, "zicada-int-test"),
            .qtype = 1,
            .qclass = 1,
        },
    };
    defer std.testing.allocator.free(query_msg.question.?.name);
    const qlen = try wire.encodeMessage(&query_buf, query_msg);

    // Bind a UDP client socket and send the query
    var src_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var src = src_addr.bind(std.testing.io, .{
        .mode = .dgram,
        .protocol = .udp,
    }) catch |err| switch (err) {
        error.AddressUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer src.close(std.testing.io);

    const dst: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    try src.send(std.testing.io, &dst, query_buf[0..qlen]);

    var recv_buf: [512]u8 = undefined;
    const recv = try src.receiveTimeout(std.testing.io, &recv_buf, .{
        .duration = .{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .real },
    });
    try std.testing.expect(!recv.flags.trunc);
    try std.testing.expect(recv.data.len >= 12);

    // Decode the response (responses have QR=1, so we can't reuse decodeQuery)
    const resp_header = try wire.Header.decode(recv.data);
    try std.testing.expectEqual(@as(u16, 0x1234), resp_header.id);
    try std.testing.expectEqual(@as(u1, 1), resp_header.flags.qr);
    try std.testing.expectEqual(@as(u4, 0), resp_header.flags.rcode);
    try std.testing.expectEqual(@as(u16, 1), resp_header.qdcount);
    try std.testing.expectEqual(@as(u16, 1), resp_header.ancount);

    // Skip header (12) + question (1+15+1+2+2 = 21) + answer header before RDATA (2+2+2+4+2 = 12).
    // RDATA for an A record is 4 bytes; check it equals 10.0.0.99.
    const rdata_offset = 12 + (1 + 15 + 1 + 2 + 2) + (2 + 2 + 2 + 4 + 2);
    try std.testing.expectEqual(@as(usize, 45), rdata_offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 99 }, recv.data[rdata_offset..][0..4]);
}

test "integration: server returns NXDOMAIN for missing name" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();
    // Make sure the key is absent
    { _ = rc.del("dns-a-zicada-nxdom-test") catch {}; }

    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13532;
    const thread = try std.Thread.spawn(.{}, runServer, .{
        std.testing.io, port, "redis://127.0.0.1:6379", &shutdown,
    });
    try Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
        .clock = .real,
    }, std.testing.io);
    defer {
        shutdown.store(true, .monotonic);
        thread.join();
    }

    var query_buf: [256]u8 = undefined;
    const query_msg: wire.Message = .{
        .header = .{
            .id = 0x5678,
            .flags = .{ .qr = 0, .opcode = 0, .aa = 0, .tc = 0, .rd = 1, .ra = 0, .z = 0, .rcode = 0 },
            .qdcount = 1,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
        .question = .{
            .name = try std.testing.allocator.dupe(u8, "zicada-nxdom-test"),
            .qtype = 1,
            .qclass = 1,
        },
    };
    defer std.testing.allocator.free(query_msg.question.?.name);
    const qlen = try wire.encodeMessage(&query_buf, query_msg);

    var src_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var src = src_addr.bind(std.testing.io, .{
        .mode = .dgram,
        .protocol = .udp,
    }) catch |err| switch (err) {
        error.AddressUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer src.close(std.testing.io);

    const dst: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    try src.send(std.testing.io, &dst, query_buf[0..qlen]);

    var recv_buf: [512]u8 = undefined;
    const recv = try src.receiveTimeout(std.testing.io, &recv_buf, .{
        .duration = .{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .real },
    });
    const resp_header = try wire.Header.decode(recv.data);
    try std.testing.expectEqual(@as(u16, 0x5678), resp_header.id);
    try std.testing.expectEqual(@as(u4, 3), resp_header.flags.rcode); // NXDOMAIN
    try std.testing.expectEqual(@as(u16, 0), resp_header.ancount);
}
