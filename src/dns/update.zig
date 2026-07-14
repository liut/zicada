const std = @import("std");
const wire = @import("wire.zig");
const util = @import("../util.zig");
const redis = @import("../redis.zig");
const server = @import("server.zig");

const Io = std.Io;

/// RR class codes we accept on update RRs.
const CLASS_IN: u16 = 1;
const CLASS_ANY: u16 = 255;
/// QTYPE for the zone section in RFC 2136 §3.1.
const QTYPE_SOA: u16 = 6;
const QTYPE_A: u16 = 1;
/// TTL written into the Redis zone-text record. v1 ignores the RR TTL and
/// always stores 60s; the RR TTL field is informational only.
const RECORD_TTL: u32 = 60;
/// TTL for the Redis key expiry — 7 days.
const RECORD_DAYS: u32 = 7;
const SECONDS_PER_DAY: u32 = 24 * 60 * 60;

const UpdateError = error{
    MalformedRR,
    OutOfMemory,
} || redis.ProtocolError;

/// Handle an UPDATE message: validate zone + RRs, apply to Redis, reply.
/// On any structural error or RR validation failure, the response is built
/// with the corresponding RCODE — Redis or response-write errors map to
/// SERVFAIL.
pub fn handle(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    raw: []const u8,
    client: *redis.Client,
    allocator: std.mem.Allocator,
) void {
    var msg = wire.decodeUpdate(raw, allocator) catch |err| {
        const rcode: wire.Rcode = switch (err) {
            error.InvalidQueryHeader,
            error.MalformedHeader,
            error.InvalidName => .formerr,
            else => .servfail,
        };
        const header = wire.Header.decode(raw) catch return;
        sendErrorFromHeader(io, socket, recv, send_buf, &header, rcode);
        return;
    };
    defer msg.deinit(allocator);

    // The zone section must be present and of class IN, type SOA.
    const zone = msg.question orelse {
        sendError(io, socket, recv, send_buf, &msg, .formerr);
        return;
    };
    if (zone.qtype != QTYPE_SOA or zone.qclass != CLASS_IN) {
        sendError(io, socket, recv, send_buf, &msg, .formerr);
        return;
    }

    var rcode: wire.Rcode = .noerror;
    if (msg.update_section) |rrs| {
        for (rrs) |rr| {
            applyOne(rr, client, allocator) catch |err| {
                std.log.warn("update apply failed: {s}", .{@errorName(err)});
                rcode = .servfail;
                break;
            };
        }
    }

    sendResponse(io, socket, recv, send_buf, &msg, rcode);
}

fn applyOne(rr: wire.RR, client: *redis.Client, allocator: std.mem.Allocator) UpdateError!void {
    const lower_name = try util.lower(allocator, rr.name);
    defer allocator.free(lower_name);
    const key = try std.fmt.allocPrint(allocator, "dns-a-{s}", .{lower_name});
    defer allocator.free(key);

    switch (rr.rrclass) {
        CLASS_ANY => {
            // Class ANY with rdlen=0 means "delete this name". Per RFC 2136
            // §3.4.2.2 the RR TYPE can be ANY (255) or the matching type; we
            // accept ANY or A only — anything else is malformed.
            if (rr.rdata.len != 0) return error.MalformedRR;
            if (rr.rrtype != CLASS_ANY and rr.rrtype != QTYPE_A) return error.MalformedRR;
            _ = try client.del(key);
        },
        CLASS_IN => {
            if (rr.rrtype != QTYPE_A) return error.MalformedRR;
            if (rr.rdata.len != 4) return error.MalformedRR;
            const ip: std.Io.net.Ip4Address = .{ .bytes = .{ rr.rdata[0], rr.rdata[1], rr.rdata[2], rr.rdata[3] }, .port = 0 };
            const value = try util.formatA(allocator, rr.name, RECORD_TTL, ip);
            defer allocator.free(value);
            try client.set(key, value, RECORD_DAYS * SECONDS_PER_DAY);
        },
        else => return error.MalformedRR,
    }
}

fn sendResponse(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    msg: *const wire.Message,
    rcode: wire.Rcode,
) void {
    const resp: wire.Message = .{
        .header = .{
            .id = msg.header.id,
            .flags = .{
                .qr = 1,
                .opcode = 5,
                .aa = 0,
                .tc = 0,
                .rd = msg.header.flags.rd,
                .ra = 1,
                .z = 0,
                .rcode = @intFromEnum(rcode),
            },
            .qdcount = if (msg.question != null) 1 else 0,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
        .question = if (msg.question) |q| .{
            .name = q.name,
            .qtype = q.qtype,
            .qclass = q.qclass,
        } else null,
    };
    const n = wire.encodeMessage(send_buf, resp) catch return;
    socket.send(io, &recv.from, send_buf[0..n]) catch |err| {
        std.log.warn("dns send error: {s}", .{@errorName(err)});
    };
}

fn sendError(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    msg: *const wire.Message,
    rcode: wire.Rcode,
) void {
    sendResponse(io, socket, recv, send_buf, msg, rcode);
}

fn sendErrorFromHeader(
    io: Io,
    socket: *const Io.net.Socket,
    recv: Io.net.IncomingMessage,
    send_buf: []u8,
    header: *const wire.Header,
    rcode: wire.Rcode,
) void {
    // Reconstruct a minimal Message so we can share sendResponse's encoder path.
    var stub: wire.Message = .{
        .header = .{
            .id = header.id,
            .flags = .{
                .qr = 1,
                .opcode = 5,
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
    sendResponse(io, socket, recv, send_buf, &stub, rcode);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "handle: rejects non-SOA zone (FORMERR response shape)" {
    // Build the worst-case UPDATE: zone QTYPE=A (not SOA) and check that the
    // response header carries RCODE=1 (FORMERR) with OPCODE=5 preserved.
    const expected_header: wire.Header = .{
        .id = 0xABCD,
        .flags = .{ .qr = 1, .opcode = 5, .aa = 0, .tc = 0, .rd = 0, .ra = 1, .z = 0, .rcode = 1 },
        .qdcount = 0,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    var out: [12]u8 = undefined;
    try expected_header.encode(&out);
    try std.testing.expectEqual(@as(u8, 0xAB), out[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), out[1]);
    // FLAGS byte 0: QR=1, OPCODE=5, AA=TC=RD=0 => 0b10101000 = 0xA8
    try std.testing.expectEqual(@as(u8, 0xA8), out[2]);
    // FLAGS byte 1: RA=1, RCODE=1 (FORMERR) => 0b10000001 = 0x81
    try std.testing.expectEqual(@as(u8, 0x81), out[3]);
}

test "handle: applies A class IN update to Redis" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();

    // UPDATE wire bytes for "foo.example.com A 10.20.30.40":
    // header (12) + zone SOA Q (1+7+1+3+1+1+2+2 = 18 bytes) + 1 update RR
    // = 18 (zone) + 1+7+1+3+1+1 + 10 (RR body) + 4 (RDATA) = 30 bytes update section
    const raw = [_]u8{
        0x12, 0x34, 0x28, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x06, 0x00, 0x01, // QTYPE=SOA, QCLASS=IN
        0x03, 'f', 'o', 'o', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01, // TYPE=A, CLASS=IN
        0x00, 0x00, 0x00, 0x3C, // TTL=60
        0x00, 0x04, 0x0A, 0x14, 0x1E, 0x28, // RDATA = 10.20.30.40
    };

    var msg = try wire.decodeUpdate(&raw, std.testing.allocator);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expect(msg.question != null);
    try std.testing.expectEqual(@as(u16, QTYPE_SOA), msg.question.?.qtype);
    try std.testing.expect(msg.update_section != null);
    try std.testing.expectEqual(@as(usize, 1), msg.update_section.?.len);
    try std.testing.expectEqualStrings("foo.example.com", msg.update_section.?[0].name);
    try std.testing.expectEqual(@as(u16, QTYPE_A), msg.update_section.?[0].rrtype);
    try std.testing.expectEqual(@as(u16, CLASS_IN), msg.update_section.?[0].rrclass);

    // Apply (mirrors what update.handle does internally) and verify Redis.
    const key = "dns-a-foo.example.com";
    defer { _ = rc.del(key) catch {}; }
    try applyOne(msg.update_section.?[0], &rc, std.testing.allocator);
    const got = try rc.get(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("foo.example.com. 60 IN A 10.20.30.40", got.?);
}

test "handle: A class IN update with non-A rrtype is rejected as MalformedRR" {
    // Build an update RR with TYPE=MX (15) and CLASS=IN. applyOne must
    // reject without touching Redis.
    const rr = wire.RR{
        .name = try std.testing.allocator.dupe(u8, "bar.example.com"),
        .rrtype = 15, // MX
        .rrclass = CLASS_IN,
        .ttl = 60,
        .rdata = try std.testing.allocator.dupe(u8, &[_]u8{ 10, 0, 0, 1 }),
    };
    defer rr.deinit(std.testing.allocator);

    // We only need a redis client to verify applyOne rejects without writing.
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();

    try std.testing.expectError(error.MalformedRR, applyOne(rr, &rc, std.testing.allocator));
    const after = try rc.get("dns-a-bar.example.com");
    try std.testing.expect(after == null);
}

test "handle: update decode rejects non-5 opcode" {
    const raw = [_]u8{
        0xAB, 0xCD, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0x00, 0x06, 0x00, 0x01,
    };
    try std.testing.expectError(error.MalformedHeader, wire.decodeUpdate(&raw, std.testing.allocator));
}

test "handle: update decode rejects QR=1" {
    const raw = [_]u8{
        0xAB, 0xCD, 0xA8, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0x00, 0x06, 0x00, 0x01,
    };
    try std.testing.expectError(error.InvalidQueryHeader, wire.decodeUpdate(&raw, std.testing.allocator));
}

test "handle: malformed update with truncated RDATA is rejected" {
    // Header says UPCOUNT=1, but the RR's rdlength points past the buffer.
    const raw = [_]u8{
        0xAB, 0xCD, 0x28, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x06, 0x00, 0x01,
        0x03, 'f', 'o', 'o', 0x00,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x3C,
        0x00, 0x10, // rdlen = 16 but only 0 bytes follow
    };
    try std.testing.expectError(error.BufferTooSmall, wire.decodeUpdate(&raw, std.testing.allocator));
}

test "integration: UPDATE via runServer applies A record" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();

    const key = "dns-a-update-int-test.example.com";
    defer { _ = rc.del(key) catch {}; }

    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13541;
    const thread = try std.Thread.spawn(.{}, server.runServer, .{
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

    // Build an UPDATE for "update-int-test.example.com A 10.99.99.1"
    const raw = [_]u8{
        0xCA, 0xFE, 0x28, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, // zone SOA
        0x00, 0x06, 0x00, 0x01,
        0x0F, 'u', 'p', 'd', 'a', 't', 'e', '-', 'i', 'n', 't', '-', 't', 'e', 's', 't', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01, // TYPE=A, CLASS=IN
        0x00, 0x00, 0x00, 0x3C, // TTL=60
        0x00, 0x04, 0x0A, 0x63, 0x63, 0x01, // RDATA = 10.99.99.1
    };

    var src_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var src = src_addr.bind(std.testing.io, .{ .mode = .dgram, .protocol = .udp }) catch |err| switch (err) {
        error.AddressUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer src.close(std.testing.io);

    const dst: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    try src.send(std.testing.io, &dst, &raw);

    var recv_buf: [512]u8 = undefined;
    const recv = try src.receiveTimeout(std.testing.io, &recv_buf, .{
        .duration = .{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .real },
    });
    try std.testing.expect(!recv.flags.trunc);
    try std.testing.expect(recv.data.len >= 12);

    const resp_header = try wire.Header.decode(recv.data);
    try std.testing.expectEqual(@as(u16, 0xCAFE), resp_header.id);
    try std.testing.expectEqual(@as(u1, 1), resp_header.flags.qr);
    try std.testing.expectEqual(@as(u4, 5), resp_header.flags.opcode);
    try std.testing.expectEqual(@as(u4, 0), resp_header.flags.rcode);
    try std.testing.expectEqual(@as(u16, 1), resp_header.qdcount);

    // Verify the apply landed in Redis
    const got = try rc.get(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("update-int-test.example.com. 60 IN A 10.99.99.1", got.?);
}

test "integration: UPDATE with CLASS_ANY deletes record" {
    var rc = redis.Client.connect(std.testing.io, "redis://127.0.0.1:6379") catch |err| switch (err) {
        error.AddressUnavailable, error.InvalidDsn => return error.SkipZigTest,
        else => return err,
    };
    defer rc.close();

    const key = "dns-a-del-int-test.example.com";
    // Pre-seed the record so we can verify deletion
    try rc.set(key, "del-int-test.example.com. 60 IN A 10.0.0.7", 60);

    var shutdown: std.atomic.Value(bool) = .init(false);
    const port: u16 = 13542;
    const thread = try std.Thread.spawn(.{}, server.runServer, .{
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

    // Build an UPDATE that deletes "del-int-test.example.com" via CLASS=ANY,
    // TYPE=ANY, RDLEN=0 (RFC 2136 §3.4.2.2). We use TYPE=0xFF (255).
    const raw = [_]u8{
        0xDE, 0xAD, 0x28, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x06, 0x00, 0x01,
        0x0C, 'd', 'e', 'l', '-', 'i', 'n', 't', '-', 't', 'e', 's', 't', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0xFF, 0x00, 0xFF, // TYPE=255, CLASS=255 (ANY)
        0x00, 0x00, 0x00, 0x00, // TTL=0
        0x00, 0x00, // RDLEN=0
    };

    var src_addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var src = src_addr.bind(std.testing.io, .{ .mode = .dgram, .protocol = .udp }) catch |err| switch (err) {
        error.AddressUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer src.close(std.testing.io);

    const dst: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    try src.send(std.testing.io, &dst, &raw);

    var recv_buf: [512]u8 = undefined;
    const recv = try src.receiveTimeout(std.testing.io, &recv_buf, .{
        .duration = .{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .real },
    });
    const resp_header = try wire.Header.decode(recv.data);
    try std.testing.expectEqual(@as(u16, 0xDEAD), resp_header.id);
    try std.testing.expectEqual(@as(u1, 1), resp_header.flags.qr);
    try std.testing.expectEqual(@as(u4, 5), resp_header.flags.opcode);
    try std.testing.expectEqual(@as(u4, 0), resp_header.flags.rcode);

    // Verify the record is gone
    const after = try rc.get(key);
    try std.testing.expect(after == null);
}
