const std = @import("std");

pub fn lower(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

pub fn trimDot(name: []const u8) []const u8 {
    if (name.len > 0 and name[name.len - 1] == '.') return name[0 .. name.len - 1];
    return name;
}

pub const IpError = error{InvalidIp};

pub fn parseIPv4(s: []const u8) IpError!std.Io.net.Ip4Address {
    return std.Io.net.Ip4Address.parse(s, 0) catch return error.InvalidIp;
}

pub fn formatA(allocator: std.mem.Allocator, name: []const u8, ttl: u32, ip: std.Io.net.Ip4Address) std.fmt.AllocPrintError![]u8 {
    const trimmed = trimDot(name);
    return std.fmt.allocPrint(allocator, "{s}. {d} IN A {d}.{d}.{d}.{d}", .{
        trimmed,
        ttl,
        ip.bytes[0],
        ip.bytes[1],
        ip.bytes[2],
        ip.bytes[3],
    });
}

test "lower ascii" {
    const out = try lower(std.testing.allocator, "App.Example.COM");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("app.example.com", out);
}

test "trimDot removes trailing dot" {
    try std.testing.expectEqualStrings("app", trimDot("app."));
    try std.testing.expectEqualStrings("app.example", trimDot("app.example"));
    try std.testing.expectEqualStrings("", trimDot("."));
}

test "parseIPv4 valid" {
    const ip = try parseIPv4("10.0.0.1");
    try std.testing.expectEqual([_]u8{ 10, 0, 0, 1 }, ip.bytes);
}

test "parseIPv4 rejects garbage" {
    try std.testing.expectError(error.InvalidIp, parseIPv4("not-an-ip"));
    try std.testing.expectError(error.InvalidIp, parseIPv4("999.0.0.1"));
    try std.testing.expectError(error.InvalidIp, parseIPv4("10.0.0"));
}

test "formatA produces zone-text with trailing dot" {
    const ip = try parseIPv4("192.168.1.100");
    const s = try formatA(std.testing.allocator, "app.example.com", 60, ip);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("app.example.com. 60 IN A 192.168.1.100", s);
}

test "formatA strips existing trailing dot" {
    const ip = try parseIPv4("10.0.0.1");
    const s = try formatA(std.testing.allocator, "host.local.", 30, ip);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("host.local. 30 IN A 10.0.0.1", s);
}