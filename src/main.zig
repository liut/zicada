const std = @import("std");

const config = @import("config.zig");

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
    var stderr_buffer: [128]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;
    try stderr_writer.print("cli-add not implemented (name={s} ip={s})\n", .{ cfg.name, cfg.ip });
    try stderr_writer.flush();
    return 1;
}

fn runServer(io: Io, cfg: *const config.Config) !u8 {
    var stderr_buffer: [128]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;
    try stderr_writer.print("server not implemented (port={d})\n", .{cfg.port});
    try stderr_writer.flush();
    return 1;
}