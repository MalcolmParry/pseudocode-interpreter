const std = @import("std");
const Lexer = @import("Lexer.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    const src =
        // \\x <- 2 - 3
        \\2 + 3 * 4
    ;

    var lexer = Lexer.init(src);
    defer lexer.deinit();

    // _ = alloc;
    // while (true) {
    //     const token = lexer.nextToken();
    //     std.log.info("{f}", .{token.data});
    //     if (token.data == .eof) break;
    // }

    const expression = try parser.parseExpression(&lexer, 0, alloc);
    std.log.info("{f}", .{expression});

    if (expression.data != .err) {
        std.log.info("{}", .{eval(expression)});
    }
}

fn eval(expression: *parser.Expression) types.Int {
    return switch (expression.data) {
        .lit => |lit| lit.int,
        .neg => |neg| -eval(neg),
        .bin => |bin| {
            const left = eval(bin.left);
            const right = eval(bin.right);

            return switch (bin.op) {
                .add => left + right,
                .sub => left - right,
                .mul => left * right,
                .div => @divTrunc(left, right),
            };
        },
        .err => -1,
    };
}
