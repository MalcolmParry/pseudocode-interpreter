const std = @import("std");
const Lexer = @import("Lexer.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    const src = "2 + -3 * 5";

    var lexer = Lexer.init(src);
    defer lexer.deinit();

    // while (true) {
    //     const token = lexer.nextTokenNoWS();
    //     std.log.info("{f}", .{token});
    //     if (token.data == .eof) break;
    // }

    const expression = try parser.parseExpression(&lexer, alloc);
    std.log.info("{f}", .{expression});
}
