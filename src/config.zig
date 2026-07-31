const std = @import("std");

const Defaults = struct {
    const port: u16 = 1353;
    const dsn: []const u8 = "redis://localhost:6379/0";
    const ttl: u32 = 60;
    const days: u32 = 7;
    const serv: bool = false;
    const gen_service: bool = false;
    const user: []const u8 = "";
    const net: []const u8 = "udp";
};

pub const Config = struct {
    port: u16,
    dsn: []u8,
    name: []u8,
    ip: []u8,
    ttl: u32,
    days: u32,
    serv: bool,
    gen_service: bool,
    user: []u8,
    net: []u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.dsn);
        allocator.free(self.name);
        allocator.free(self.ip);
        allocator.free(self.user);
        allocator.free(self.net);
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlag,
    InvalidValue,
    OutOfMemory,
};

/// Parse CLI arguments into a Config.
/// Recognised forms: `-flag value` and `-flag=value` (also `--flag`).
/// Bool flags (`-serv`) accept only the no-value form; `-serv=true|1|false|0` is also accepted.
pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) ParseError!Config {
    var cfg: Config = .{
        .port = Defaults.port,
        .dsn = try allocator.dupe(u8, Defaults.dsn),
        .name = try allocator.dupe(u8, ""),
        .ip = try allocator.dupe(u8, ""),
        .ttl = Defaults.ttl,
        .days = Defaults.days,
        .serv = Defaults.serv,
        .gen_service = Defaults.gen_service,
        .user = try allocator.dupe(u8, Defaults.user),
        .net = try allocator.dupe(u8, Defaults.net),
    };
    errdefer cfg.deinit(allocator);

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const raw = args[i];
        if (raw.len == 0 or raw[0] != '-') return error.UnknownFlag;

        const eq: ?usize = std.mem.indexOfScalar(u8, raw, '=');
        const head_raw = if (eq) |e| raw[0..e] else raw;
        const inline_value: ?[]const u8 = if (eq) |e| raw[e + 1 ..] else null;

        var name_start: usize = 0;
        while (name_start < head_raw.len and head_raw[name_start] == '-') name_start += 1;
        const name = head_raw[name_start..];

        if (std.mem.eql(u8, name, "serv")) {
            if (inline_value) |v| {
                if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) {
                    cfg.serv = true;
                } else if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) {
                    cfg.serv = false;
                } else return error.InvalidValue;
            } else {
                cfg.serv = true;
            }
            continue;
        }

        if (std.mem.eql(u8, name, "gen-service")) {
            if (inline_value) |v| {
                if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) {
                    cfg.gen_service = true;
                } else if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) {
                    cfg.gen_service = false;
                } else return error.InvalidValue;
            } else {
                cfg.gen_service = true;
            }
            continue;
        }

        const value = inline_value orelse blk: {
            if (i + 1 >= args.len) return error.InvalidValue;
            i += 1;
            break :blk args[i];
        };

        if (std.mem.eql(u8, name, "port")) {
            cfg.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            if (cfg.port == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "dsn")) {
            allocator.free(cfg.dsn);
            cfg.dsn = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "name")) {
            allocator.free(cfg.name);
            cfg.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "ip")) {
            allocator.free(cfg.ip);
            cfg.ip = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "ttl")) {
            cfg.ttl = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "days")) {
            cfg.days = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (cfg.days == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "net")) {
            allocator.free(cfg.net);
            cfg.net = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "user")) {
            allocator.free(cfg.user);
            cfg.user = try allocator.dupe(u8, value);
        } else {
            return error.UnknownFlag;
        }
    }

    if (cfg.ip.len > 0 and cfg.name.len == 0) return error.MissingFlag;

    return cfg;
}

test "defaults" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{"zicada"});
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(u16, 1353), cfg.port);
    try std.testing.expectEqualStrings("redis://localhost:6379/0", cfg.dsn);
    try std.testing.expectEqual(@as(u32, 60), cfg.ttl);
    try std.testing.expectEqual(@as(u32, 7), cfg.days);
    try std.testing.expect(!cfg.serv);
    try std.testing.expectEqualStrings("udp", cfg.net);
}

test "happy path -name -ip" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-name", "foo", "-ip", "10.0.0.1" });
    defer cfg.deinit(a);
    try std.testing.expectEqualStrings("foo", cfg.name);
    try std.testing.expectEqualStrings("10.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u32, 7), cfg.days);
    try std.testing.expectEqual(@as(u32, 60), cfg.ttl);
}

test "inline -flag=value form" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-port=5353", "-dsn=redis://x:1/0", "-ttl=120", "-days=14", "-net=tcp", "-serv=true" });
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(u16, 5353), cfg.port);
    try std.testing.expectEqualStrings("redis://x:1/0", cfg.dsn);
    try std.testing.expectEqual(@as(u32, 120), cfg.ttl);
    try std.testing.expectEqual(@as(u32, 14), cfg.days);
    try std.testing.expectEqualStrings("tcp", cfg.net);
    try std.testing.expect(cfg.serv);
}

test "bool -gen-service presence-only" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-gen-service" });
    defer cfg.deinit(a);
    try std.testing.expect(cfg.gen_service);
    try std.testing.expect(!cfg.serv);
}

test "bool -gen-service=true" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-gen-service=true" });
    defer cfg.deinit(a);
    try std.testing.expect(cfg.gen_service);
}

test "bool -gen-service=false" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-gen-service=false" });
    defer cfg.deinit(a);
    try std.testing.expect(!cfg.gen_service);
}

test "-gen-service with bad value" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-gen-service=maybe" }));
}

test "bool -serv presence-only" {
    const a = std.testing.allocator;
    var cfg = try parse(a, &.{ "zicada", "-serv" });
    defer cfg.deinit(a);
    try std.testing.expect(cfg.serv);
}

test "-port=0 rejected" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-port", "0" }));
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-port=0" }));
}

test "-days=0 rejected" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-days", "0" }));
}

test "missing -name when -ip set" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingFlag, parse(a, &.{ "zicada", "-ip", "10.0.0.1" }));
}

test "unknown flag rejected" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownFlag, parse(a, &.{ "zicada", "-wat", "x" }));
    try std.testing.expectError(error.UnknownFlag, parse(a, &.{ "zicada", "positional" }));
}

test "-serv with bad value" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-serv=maybe" }));
}

test "flag missing value at end" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(a, &.{ "zicada", "-port" }));
}