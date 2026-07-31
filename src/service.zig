const std = @import("std");
const config = @import("config.zig");

const Io = std.Io;

/// Generate a systemd service unit file as an allocated string.
/// Caller owns the returned memory.
pub fn genUnit(io: Io, allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    const exe_path: [:0]const u8 = std.process.executablePathAlloc(io, allocator) catch |err| {
        return err;
    };
    defer allocator.free(exe_path);

    // Reject paths with characters that break systemd ExecStart
    if (std.mem.indexOfAny(u8, exe_path, "\n\r") != null) return error.InvalidPath;

    // Validate user flag: reject newlines and other injection chars
    if (cfg.user.len > 0) {
        if (std.mem.indexOfAny(u8, cfg.user, "\n\r:=") != null) return error.InvalidUser;
    }

    const port_default: u16 = 1353;

    // EnvironmentFile path: root → /etc/default/zicada, user → %h/.config/zicada.env
    const env_file_path = if (std.c.getuid() == 0)
        "-/etc/default/zicada"
    else
        "-%h/.config/zicada.env";

    const exec_start = try buildExecStart(allocator, exe_path, cfg.port, port_default);
    defer allocator.free(exec_start);

    const user_line = try buildUserLine(allocator, cfg.user);
    defer if (user_line.len > 0) allocator.free(user_line);

    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=zicada DNS server
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\EnvironmentFile={s}
        \\ExecStart={s}
        \\ExecReload=/bin/kill -HUP $MAINPID
        \\Restart=on-failure
        \\{s}
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ env_file_path, exec_start, user_line });
}

fn buildExecStart(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    port: u16,
    port_default: u16,
) ![]u8 {
    if (port != port_default) {
        return std.fmt.allocPrint(allocator, "{s} -serv -port {d}", .{ exe_path, port });
    } else {
        return std.fmt.allocPrint(allocator, "{s} -serv", .{exe_path});
    }
}

fn buildUserLine(allocator: std.mem.Allocator, user_flag: []const u8) ![]u8 {
    if (user_flag.len > 0) {
        return std.fmt.allocPrint(allocator, "User={s}\n", .{user_flag});
    }
    if (std.c.getuid() == 0) {
        return std.fmt.allocPrint(allocator, "User=nobody\n", .{});
    }
    return &.{};
}

test "genUnit default config contains all sections" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 1353,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, ""),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "[Unit]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "[Service]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "[Install]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "ExecStart="));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "ExecReload="));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "Restart=on-failure"));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "Type=simple"));
    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "EnvironmentFile="));
}

test "genUnit custom port in ExecStart" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 2053,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, ""),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "-port 2053"));
}

test "genUnit default port omits port from ExecStart" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 1353,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, ""),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    try std.testing.expect(!std.mem.containsAtLeast(u8, unit, 1, "-port 1353"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, unit, 1, "-dsn"));
}

test "genUnit ExecStart path is absolute" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 1353,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, ""),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    const exec_start_idx = std.mem.indexOf(u8, unit, "ExecStart=") orelse unreachable;
    const path_start = exec_start_idx + "ExecStart=".len;
    const path_end = std.mem.indexOfScalarPos(u8, unit, path_start, ' ') orelse unit.len;
    const path = unit[path_start..path_end];
    try std.testing.expect(path.len > 0 and path[0] == '/');
}

test "genUnit explicit user flag" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 1353,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, "zicada"),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "User=zicada"));
}

test "genUnit has EnvironmentFile" {
    const a = std.testing.allocator;
    var cfg: config.Config = .{
        .port = 1353,
        .dsn = try a.dupe(u8, "redis://localhost:6379/0"),
        .name = try a.dupe(u8, ""),
        .ip = try a.dupe(u8, ""),
        .ttl = 60,
        .days = 7,
        .serv = false,
        .gen_service = false,
        .net = try a.dupe(u8, "udp"),
        .user = try a.dupe(u8, ""),
    };
    defer cfg.deinit(a);

    const io = std.testing.io;

    const unit = try genUnit(io, a, &cfg);
    defer a.free(unit);

    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "EnvironmentFile="));
}