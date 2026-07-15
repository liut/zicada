const std = @import("std");

const config = @import("config.zig");
const redis = @import("redis.zig");
const util = @import("util.zig");
const wire = @import("dns/wire.zig");
const dns_server = @import("dns/server.zig");
const http_server = @import("http/server.zig");
comptime {
    _ = config;
    _ = redis;
    _ = util;
    _ = wire;
    _ = dns_server;
    _ = http_server;
    _ = @import("dns/update.zig");
}

const usage =
    \\Usage:
    \\  zicada -name <host> -ip <ipv4> [-ttl <sec>] [-days <n>]
    \\  zicada -serv [-port <n>] [-dsn <url>] [-net udp|tcp]
    \\
    \\Flags:
    \\  -port <n>       listen port (default 1353)
    \\  -dsn <url>      redis dsn (default redis://localhost:6379/0)
    \\  -name <host>    host name for cli add
    \\  -ip <ipv4>      ip address for cli add
    \\  -ttl <sec>      RR ttl in seconds (default 60)
    \\  -days <n>       redis expire in days (default 7)
    \\  -serv           run as dns server
    \\  -net <proto>    network: udp|tcp (default udp)
;

const Io = std.Io;

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

fn runServer(io: Io, cfg: *const config.Config) !u8 {
    var stderr_buffer: [128]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;
    try stderr_writer.print("server not implemented (port={d})\n", .{cfg.port});
    try stderr_writer.flush();
    return 1;
}