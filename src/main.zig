const std = @import("std");

const Server = std.http.Server;

var server_gpa = std.heap.GeneralPurposeAllocator(.{}){};
const server_allocator = server_gpa.allocator();

pub fn main() !void {
    var server = Server.init(server_allocator, .{ .reuse_address = true });
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    try server.listen(address);

    const num_threads = 4; //try std.Thread.getCpuCount();
    const threads = try server_allocator.alloc(std.Thread, num_threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{&server});
    }

    std.debug.print("listening on http://{}\n", .{server.socket.listen_address});

    for (threads) |t| {
        t.join();
    }
}

fn worker(server: *Server) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const worker_allocator = gpa.allocator();

    var headers_buffer = try worker_allocator.alloc(u8, 8 * 1024);
    defer worker_allocator.free(headers_buffer);

    var arena = std.heap.ArenaAllocator.init(worker_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });

        var header_buf: [8192]u8 = undefined;

        var res = try server.accept(.{ .allocator = allocator, .header_strategy = .{ .static = &header_buf } });
        defer res.deinit();

        var kept_alive: u8 = 0;
        while (res.reset() != .closing) {
            res.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => break,
                else => {
                    res.status = .bad_request;
                    res.do() catch break;
                    continue;
                },
            };

            if (kept_alive > 128) {
                try res.headers.append("connection", "close");
            }

            handler(&res) catch |err| {
                if (err == error.ConnectionResetByPeer) {
                    break;
                }

                std.debug.print("handler error {}\n", .{err});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }

                break;
            };

            kept_alive += 1;
        }
    }
}

fn handler(res: *Server.Response) !void {
    if (res.request.method != .GET) {
        res.status = .method_not_allowed;
        try res.do();

        return;
    }

    if (std.mem.eql(u8, res.request.target, "/")) {
        res.status = .ok;
        try res.headers.append("Content-Type", "text/plain");

        res.transfer_encoding = .{ .content_length = 14 };
        try res.do();

        try res.writeAll("Hello, World!\n");
        try res.finish();

        return;
    }

    res.status = .not_found;
    try res.do();

    return;
}
