const std = @import("std");

pub const WireError = error{
    BufferTooSmall,
    InvalidName,
    UnsupportedCompression,
    InvalidQueryHeader,
    OpcodeNotImplemented,
    MalformedHeader,
};

/// DNS message header (RFC 1035 §4.1.1) — 12 bytes, all multi-byte fields in
/// network (big-endian) byte order on the wire.
pub const Header = struct {
    id: u16,
    flags: Flags,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    pub fn encode(self: Header, buf: []u8) !void {
        if (buf.len < 12) return error.BufferTooSmall;
        std.mem.writeInt(u16, buf[0..2], self.id, .big);
        std.mem.writeInt(u16, buf[2..4], self.flags.toU16(), .big);
        std.mem.writeInt(u16, buf[4..6], self.qdcount, .big);
        std.mem.writeInt(u16, buf[6..8], self.ancount, .big);
        std.mem.writeInt(u16, buf[8..10], self.nscount, .big);
        std.mem.writeInt(u16, buf[10..12], self.arcount, .big);
    }

    pub fn decode(buf: []const u8) !Header {
        if (buf.len < 12) return error.BufferTooSmall;
        return .{
            .id = std.mem.readInt(u16, buf[0..2], .big),
            .flags = Flags.fromU16(std.mem.readInt(u16, buf[2..4], .big)),
            .qdcount = std.mem.readInt(u16, buf[4..6], .big),
            .ancount = std.mem.readInt(u16, buf[6..8], .big),
            .nscount = std.mem.readInt(u16, buf[8..10], .big),
            .arcount = std.mem.readInt(u16, buf[10..12], .big),
        };
    }
};

/// Header FLAGS word (RFC 1035 §4.1.1, network byte order on the wire).
/// Reading the word from the high bit down: QR | Opcode | AA | TC | RD | RA | Z | RCODE.
/// Packed-struct memory layout is LSB-first, so the bitCast to u16 yields a value
/// whose bytes match the network representation when written with `.big` endianness.
pub const Flags = packed struct(u16) {
    rcode: u4,
    z: u3,
    ra: u1,
    rd: u1,
    tc: u1,
    aa: u1,
    opcode: u4,
    qr: u1,

    pub fn toU16(self: Flags) u16 {
        return @bitCast(self);
    }

    pub fn fromU16(v: u16) Flags {
        return @bitCast(v);
    }
};

pub const Question = struct {
    name: []u8,
    qtype: u16,
    qclass: u16,
};

pub const Answer = struct {
    name: []u8,
    rrtype: u16,
    rrclass: u16,
    ttl: u32,
    rdata: []const u8,
};

pub const Message = struct {
    header: Header,
    question: ?Question = null,
    answer: ?Answer = null,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.question) |q| allocator.free(q.name);
        if (self.answer) |a| allocator.free(a.name);
    }
};

/// Standard DNS RCODE values carried in the header's 4-bit rcode field.
pub const Rcode = enum(u4) {
    noerror = 0,
    formerr = 1,
    servfail = 2,
    nxdomain = 3,
    notimp = 4,
    refused = 5,
};

pub fn setRcode(msg: *Message, code: Rcode) void {
    msg.header.flags.rcode = @intFromEnum(code);
}

pub const DecodeNameResult = struct {
    name: []u8,
    next_offset: usize,
};

/// Encode a dotted name (e.g. "app.example.com") into DNS label form:
/// `len | label | len | label | ... | 0`. Returns the number of bytes written,
/// including the trailing zero. A trailing dot is tolerated and ignored.
pub fn encodeName(buf: []u8, name: []const u8) !usize {
    if (name.len == 0) return error.InvalidName;
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0) break;
        if (label.len > 63) return error.InvalidName;
        if (pos + 1 + label.len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(label.len);
        @memcpy(buf[pos + 1..][0..label.len], label);
        pos += 1 + label.len;
    }
    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = 0;
    return pos + 1;
}

/// Decode a label-formatted name starting at `start` into a dotted string.
/// Rejects compression pointers (0xC0 <offset>) — v1 never needs to follow
/// them because Redis values arrive as zone-text that the response encoder
/// re-emits with explicit labels. The returned `name` is owned by the caller.
pub fn decodeName(buf: []const u8, start: usize, allocator: std.mem.Allocator) !DecodeNameResult {
    var pos = start;
    var name: std.ArrayList(u8) = .empty;
    errdefer name.deinit(allocator);
    var first = true;
    while (true) {
        if (pos >= buf.len) return error.BufferTooSmall;
        const len = buf[pos];
        if (len == 0) {
            pos += 1;
            break;
        }
        if ((len & 0xC0) == 0xC0) return error.UnsupportedCompression;
        if ((len & 0xC0) != 0) return error.InvalidName;
        if (len > 63) return error.InvalidName;
        if (pos + 1 + @as(usize, len) > buf.len) return error.BufferTooSmall;
        if (!first) try name.append(allocator, '.');
        try name.appendSlice(allocator, buf[pos + 1..][0..len]);
        pos += 1 + @as(usize, len);
        first = false;
    }
    return .{ .name = try name.toOwnedSlice(allocator), .next_offset = pos };
}

/// Encode a full DNS message. Answer names are emitted as a `0xC0 0x0C`
/// back-pointer to offset 12 (start of the question section), which is
/// correct for v1 because responses always echo the single question.
pub fn encodeMessage(buf: []u8, msg: Message) !usize {
    if (buf.len < 12) return error.BufferTooSmall;
    try msg.header.encode(buf[0..12]);
    var pos: usize = 12;
    if (msg.question) |q| {
        pos += try encodeName(buf[pos..], q.name);
        if (pos + 4 > buf.len) return error.BufferTooSmall;
        std.mem.writeInt(u16, buf[pos..][0..2], q.qtype, .big);
        std.mem.writeInt(u16, buf[pos + 2..][0..2], q.qclass, .big);
        pos += 4;
    }
    if (msg.answer) |a| {
        if (msg.question == null) return error.MalformedHeader;
        if (pos + 10 + a.rdata.len > buf.len) return error.BufferTooSmall;
        buf[pos] = 0xC0;
        buf[pos + 1] = 0x0C;
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], a.rrtype, .big);
        std.mem.writeInt(u16, buf[pos + 2..][0..2], a.rrclass, .big);
        std.mem.writeInt(u32, buf[pos + 4..][0..4], a.ttl, .big);
        std.mem.writeInt(u16, buf[pos + 8..][0..2], @intCast(a.rdata.len), .big);
        @memcpy(buf[pos + 10..][0..a.rdata.len], a.rdata);
        pos += 10 + a.rdata.len;
    }
    return pos;
}

/// Decode a query message from raw bytes. Validates structural rules:
/// QR=0, OPCODE in {0 (QUERY), 4 (NOTIFY), 5 (UPDATE)}, QDCOUNT=1.
/// OPCODE 1/2/3 are rejected as `OpcodeNotImplemented` since the server
/// only knows how to answer those three; OPCODE > 5 and QDCOUNT != 1 are
/// rejected as `MalformedHeader` because the wire format reserves no bits
/// for them. The returned Message owns `question.name`; call `deinit` to free.
pub fn decodeQuery(buf: []const u8, allocator: std.mem.Allocator) !Message {
    const header = try Header.decode(buf);
    if (header.flags.qr != 0) return error.InvalidQueryHeader;
    if (header.flags.opcode > 5) return error.MalformedHeader;
    if (header.flags.opcode == 1 or header.flags.opcode == 2 or header.flags.opcode == 3) {
        return error.OpcodeNotImplemented;
    }
    if (header.qdcount != 1) return error.MalformedHeader;

    const name_result = try decodeName(buf, 12, allocator);
    errdefer allocator.free(name_result.name);
    if (name_result.name.len == 0) return error.InvalidName;

    const qtype_offset = name_result.next_offset;
    if (qtype_offset + 4 > buf.len) return error.BufferTooSmall;
    const qtype = std.mem.readInt(u16, buf[qtype_offset..][0..2], .big);
    const qclass = std.mem.readInt(u16, buf[qtype_offset + 2..][0..2], .big);

    return .{
        .header = header,
        .question = .{
            .name = name_result.name,
            .qtype = qtype,
            .qclass = qclass,
        },
        .answer = null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "header encode/decode round-trip" {
    const original = Header{
        .id = 0xABCD,
        .flags = .{ .qr = 1, .opcode = 5, .aa = 1, .tc = 0, .rd = 1, .ra = 1, .z = 0, .rcode = 4 },
        .qdcount = 1,
        .ancount = 2,
        .nscount = 0,
        .arcount = 0,
    };
    var buf: [12]u8 = undefined;
    try original.encode(&buf);
    const decoded = try Header.decode(&buf);
    try std.testing.expectEqual(original.id, decoded.id);
    try std.testing.expectEqual(original.flags, decoded.flags);
    try std.testing.expectEqual(original.qdcount, decoded.qdcount);
    try std.testing.expectEqual(original.ancount, decoded.ancount);
    try std.testing.expectEqual(original.nscount, decoded.nscount);
    try std.testing.expectEqual(original.arcount, decoded.arcount);
}

test "encodeName produces label form" {
    var buf: [128]u8 = undefined;
    const n = try encodeName(&buf, "app.example.com");
    const expected = [_]u8{
        0x03, 'a', 'p', 'p',
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "encodeName strips trailing dot" {
    var buf: [128]u8 = undefined;
    const n = try encodeName(&buf, "app.example.com.");
    const expected = [_]u8{
        0x03, 'a', 'p', 'p',
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "encodeName encodes root as just terminator" {
    var buf: [128]u8 = undefined;
    const n = try encodeName(&buf, ".");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "encodeName rejects empty name" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidName, encodeName(&buf, ""));
}

test "encodeName rejects label over 63 bytes" {
    var buf: [128]u8 = undefined;
    const long_label = "a" ** 64;
    try std.testing.expectError(error.InvalidName, encodeName(&buf, long_label));
}

test "decodeName reads label form and reports next offset" {
    const bytes = [_]u8{
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0xAA, 0xBB,
    };
    const result = try decodeName(&bytes, 0, std.testing.allocator);
    defer std.testing.allocator.free(result.name);
    try std.testing.expectEqualStrings("app.example.com", result.name);
    try std.testing.expectEqual(@as(usize, 17), result.next_offset);
}

test "decodeName rejects compression pointer" {
    const bytes = [_]u8{ 0xC0, 0x0C, 0x00 };
    try std.testing.expectError(error.UnsupportedCompression, decodeName(&bytes, 0, std.testing.allocator));
}

test "decodeName rejects label with reserved bits" {
    const bytes = [_]u8{ 0x40, 'a', 0x00 };
    try std.testing.expectError(error.InvalidName, decodeName(&bytes, 0, std.testing.allocator));
}

test "decodeName rejects label over 63 bytes" {
    var bytes: [70]u8 = undefined;
    bytes[0] = 64;
    for (1..65) |i| bytes[i] = 'a';
    bytes[65] = 0;
    try std.testing.expectError(error.InvalidName, decodeName(&bytes, 0, std.testing.allocator));
}

test "encodeMessage: query matches hand-rolled bytes" {
    const expected = [_]u8{
        0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p',
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    var buf: [128]u8 = undefined;
    const msg = Message{
        .header = .{
            .id = 0x1234,
            .flags = .{ .qr = 0, .opcode = 0, .aa = 0, .tc = 0, .rd = 0, .ra = 0, .z = 0, .rcode = 0 },
            .qdcount = 1,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
        .question = .{
            .name = try std.testing.allocator.dupe(u8, "app.example.com"),
            .qtype = 1,
            .qclass = 1,
        },
    };
    defer std.testing.allocator.free(msg.question.?.name);
    const n = try encodeMessage(&buf, msg);
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "encodeMessage: response with A answer uses 0xC0 0x0C back-pointer" {
    const expected = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p',
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
        0x00, 0x01, 0x00, 0x01,
        0xC0, 0x0C,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x3C,
        0x00, 0x04,
        0x0A, 0x00, 0x00, 0x01,
    };
    const rdata = [_]u8{ 10, 0, 0, 1 };
    const msg = Message{
        .header = .{
            .id = 0x1234,
            .flags = .{ .qr = 1, .opcode = 0, .aa = 0, .tc = 0, .rd = 1, .ra = 1, .z = 0, .rcode = 0 },
            .qdcount = 1,
            .ancount = 1,
            .nscount = 0,
            .arcount = 0,
        },
        .question = .{
            .name = try std.testing.allocator.dupe(u8, "app.example.com"),
            .qtype = 1,
            .qclass = 1,
        },
        .answer = .{
            .name = try std.testing.allocator.dupe(u8, "app.example.com"),
            .rrtype = 1,
            .rrclass = 1,
            .ttl = 60,
            .rdata = &rdata,
        },
    };
    defer std.testing.allocator.free(msg.question.?.name);
    defer std.testing.allocator.free(msg.answer.?.name);

    var buf: [128]u8 = undefined;
    const n = try encodeMessage(&buf, msg);
    try std.testing.expectEqual(@as(usize, expected.len), n);
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "decodeQuery: happy path parses fields" {
    const bytes = [_]u8{
        0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    var msg = try decodeQuery(&bytes, std.testing.allocator);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 0x1234), msg.header.id);
    try std.testing.expectEqual(@as(u1, 0), msg.header.flags.qr);
    try std.testing.expect(msg.question != null);
    try std.testing.expectEqualStrings("app.example.com", msg.question.?.name);
    try std.testing.expectEqual(@as(u16, 1), msg.question.?.qtype);
    try std.testing.expectEqual(@as(u16, 1), msg.question.?.qclass);
    try std.testing.expect(msg.answer == null);
}

test "decodeQuery then encodeMessage round-trips query bytes" {
    const bytes = [_]u8{
        0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    var msg = try decodeQuery(&bytes, std.testing.allocator);
    defer msg.deinit(std.testing.allocator);

    var buf: [128]u8 = undefined;
    const n = try encodeMessage(&buf, msg);
    try std.testing.expectEqualSlices(u8, &bytes, buf[0..n]);
}

test "decodeQuery rejects QR=1" {
    const bytes = [_]u8{
        0x12, 0x34, 0x80, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.InvalidQueryHeader, decodeQuery(&bytes, std.testing.allocator));
}

test "decodeQuery rejects OPCODE=2 (STATUS)" {
    const bytes = [_]u8{
        0x12, 0x34, 0x10, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.OpcodeNotImplemented, decodeQuery(&bytes, std.testing.allocator));
}

test "decodeQuery rejects OPCODE=6 (reserved)" {
    const bytes = [_]u8{
        0x12, 0x34, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.MalformedHeader, decodeQuery(&bytes, std.testing.allocator));
}

test "decodeQuery rejects QDCOUNT=2" {
    const bytes = [_]u8{
        0x12, 0x34, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.MalformedHeader, decodeQuery(&bytes, std.testing.allocator));
}

test "decodeQuery rejects empty name (root only)" {
    const bytes = [_]u8{
        0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.InvalidName, decodeQuery(&bytes, std.testing.allocator));
}

test "decodeQuery rejects compression pointer in question" {
    const bytes = [_]u8{
        0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x0C,
        0x00, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.UnsupportedCompression, decodeQuery(&bytes, std.testing.allocator));
}

test "setRcode updates flags.rcode" {
    var msg = Message{
        .header = .{
            .id = 0,
            .flags = .{ .qr = 0, .opcode = 0, .aa = 0, .tc = 0, .rd = 0, .ra = 0, .z = 0, .rcode = 0 },
            .qdcount = 1,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
    };
    setRcode(&msg, .nxdomain);
    try std.testing.expectEqual(@as(u4, 3), msg.header.flags.rcode);
}

test "encodeMessage: response with NXDOMAIN sets rcode but no answer" {
    const expected = [_]u8{
        0x12, 0x34, 0x81, 0x83, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 'a', 'p', 'p', 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
        0x00, 0x01, 0x00, 0x01,
    };
    const msg = Message{
        .header = .{
            .id = 0x1234,
            .flags = .{ .qr = 1, .opcode = 0, .aa = 0, .tc = 0, .rd = 1, .ra = 1, .z = 0, .rcode = 3 },
            .qdcount = 1,
            .ancount = 0,
            .nscount = 0,
            .arcount = 0,
        },
        .question = .{
            .name = try std.testing.allocator.dupe(u8, "app.example.com"),
            .qtype = 1,
            .qclass = 1,
        },
    };
    defer std.testing.allocator.free(msg.question.?.name);

    var buf: [128]u8 = undefined;
    const n = try encodeMessage(&buf, msg);
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}
