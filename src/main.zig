const std = @import("std");
const Lexer = @import("Lexer.zig");

pub fn main() !void {
    const src = "2 + 3 * 5";

    var lexer = Lexer.init(src);
    defer lexer.deinit();

    while (true) {
        const token = lexer.nextToken();
        if (token.data == .whitespace) continue;
        std.log.info("{f}", .{token});
        if (token.data == .eof) break;
    }
}
