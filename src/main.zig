const std = @import("std");

const config = @import("config.zig");
const redis = @import("redis.zig");
const service = @import("service.zig");
const util = @import("util.zig");
const wire = @import("dns/wire.zig");
const dns_server = @import("dns/server.zig");
const http_server = @import("http/server.zig");
const log = @import("log.zig");
comptime {
    _ = config;
    _ = redis;
    _ = service;
    _ = util;
    _ = wire;
    _ = dns_server;
    _ = http_server;
    _ = log;
    _ = @import("dns/update.zig");
}

const VERSION: []const u8 = "0.1.0";

const usage =
    \\Usage:
    \\  zicada -name <host> -ip <ipv4> [-ttl <sec>] [-days <n>]
    \\  zicada -gen-service [-port <n>] [-user <name>]
    \\  zicada -serv [-port <n>] [-dsn <url>] [-net udp|tcp]
    \\
    \\Flags:
    \\  -port <n>       listen port (default 1353)
    \\  -dsn <url>      redis dsn (default redis://localhost:6379/0)
    \\  -name <host>    host name for cli add
    \\  -ip <ipv4>      ip address for cli add
    \\  -ttl <sec>      RR ttl in seconds (default 60)
    \\  -days <n>       redis expire in days (default 7)
    \\  -gen-service    print systemd service unit to stdout
    \\  -user <name>    service user (default: nobody when root, none otherwise)
    \\  -serv           run as dns server
    \\  -net <proto>    network: udp|tcp (default udp)
    \\
;

const Io = std.Io;

/// Flipped by the SIGINT/SIGTERM handler. Held in module scope because a
/// signal handler cannot safely access function-scoped Zig state. Stores
/// are atomic; loads are atomic; this is async-signal-safe.
var g_shutdown: std.atomic.Value(bool) = .init(false);

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_shutdown.store(true, .monotonic);
}

fn installSignalHandlers() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
}

pub fn main(init: std.process.Init) !u8 {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var cfg = config.parse(arena, args) catch |err| {
        var stderr_buffer: [512]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        switch (err) {
            error.UnknownFlag => try stderr_writer.print("error: unknown flag\n{s}", .{usage}),
            error.MissingFlag => try stderr_writer.print("error: -ip given without -name\n{s}", .{usage}),
            error.InvalidValue => try stderr_writer.print("error: invalid value for flag\n{s}", .{usage}),
            error.OutOfMemory => return 1,
        }
        try stderr_writer.flush();
        return 2;
    };
    defer cfg.deinit(arena);

    const want_cli_add = cfg.name.len > 0 and cfg.ip.len > 0;
    if (want_cli_add) return runCliAdd(io, &cfg);
    if (cfg.gen_service) return runGenService(io, &cfg);
    if (cfg.serv) return runServer(io, &cfg);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;
    try stderr_writer.print("{s}", .{usage});
    try stderr_writer.flush();
    return 2;
}

fn runCliAdd(io: Io, cfg: *const config.Config) !u8 {
    const allocator = std.heap.page_allocator;

    const ip = util.parseIPv4(cfg.ip) catch {
        var stderr_buffer: [128]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        try stderr_writer.print("error: invalid ip '{s}'\n", .{cfg.ip});
        try stderr_writer.flush();
        return 1;
    };

    const lower_name = try util.lower(allocator, util.trimDot(cfg.name));
    defer allocator.free(lower_name);

    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "dns-a-{s}", .{lower_name}) catch {
        var stderr_buffer: [128]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        try stderr_writer.print("error: name too long\n", .{});
        try stderr_writer.flush();
        return 1;
    };

    const value = try util.formatA(allocator, cfg.name, cfg.ttl, ip);
    defer allocator.free(value);

    var client = redis.Client.connect(io, cfg.dsn) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        try stderr_writer.print("error: redis connect failed: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return 1;
    };
    defer client.close();

    const ttl_seconds: u32 = cfg.days * 24 * 60 * 60;
    client.set(key, value, ttl_seconds) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        try stderr_writer.print("error: redis SET failed: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return 1;
    };

    var stdout_buffer: [512]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("{s} {s}\n", .{ key, value });
    try stdout_writer.flush();
    return 0;
}

fn runGenService(io: Io, cfg: *const config.Config) !u8 {
    const allocator = std.heap.page_allocator;

    const unit = service.genUnit(io, allocator, cfg) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        const stderr_writer = &stderr_file_writer.interface;
        try stderr_writer.print("error: failed to generate unit: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return 1;
    };
    defer allocator.free(unit);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("{s}", .{unit});
    try stdout_writer.flush();
    return 0;
}

/// Run DNS (UDP, port) and HTTP (TCP, port+1) servers concurrently. Blocks
/// until SIGINT/SIGTERM/SIGHUP, then drains the DNS thread (which polls
/// shutdown via `receiveTimeout`) and detaches the HTTP thread (whose
/// `listener.accept` is uncancellable). Exits within ~1s of the signal.
fn runServer(io: Io, cfg: *const config.Config) !u8 {
    installSignalHandlers();

    // ZICADA_DSN env var override for server mode (set by systemd EnvironmentFile)
    var dsn_override: ?[]const u8 = null;
    if (std.c.getenv("ZICADA_DSN")) |env_ptr| {
        const env_dsn = std.mem.span(env_ptr);
        if (std.mem.eql(u8, cfg.dsn, "redis://localhost:6379/0") and env_dsn.len > 0) {
            dsn_override = env_dsn;
        }
    }

    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{cfg.port}) catch "?";

    var stdout_buf: [512]u8 = undefined;
    log.event(io, &stdout_buf, .info, "main", "starting", &[_]log.Field{
        .{ .key = "ver", .value = VERSION },
        .{ .key = "net", .value = "udp" },
        .{ .key = "port", .value = port_str },
        .{ .key = "dns_http_port", .value = "port+1" },
    });

    // Per-invocation shutdown flag, passed by pointer to both servers.
    g_shutdown.store(false, .monotonic);

    const dsn = dsn_override orelse cfg.dsn;
    const dns_thread = try std.Thread.spawn(.{}, dns_server.runServer, .{
        io, cfg.port, dsn, &g_shutdown,
    });
    errdefer {
        g_shutdown.store(true, .monotonic);
        dns_thread.join();
    }

    const http_thread = try std.Thread.spawn(.{}, http_server.runServer, .{
        io, cfg.port, dsn, &g_shutdown,
    });
    errdefer {
        g_shutdown.store(true, .monotonic);
        http_thread.detach();
        dns_thread.join();
    }

    while (!g_shutdown.load(.monotonic)) {
        try Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = std.time.ns_per_ms * 100 },
            .clock = .real,
        }, io);
    }

    log.event(io, &stdout_buf, .info, "main", "shutdown received", &.{});

    // DNS polls the flag via receiveTimeout (sub-second cadence), so a
    // bounded join is enough. HTTP's accept() blocks forever though —
    // detach it so the process can exit cleanly.
    dns_thread.join();
    http_thread.detach();

    log.event(io, &stdout_buf, .info, "main", "shutdown complete", &.{});
    return 0;
}
