const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const types = @import("types.zig");

pub fn main() !void {
    const src =
        // \\x <- 2 - 3
        \\2 + 3 * 4
    ;

    var lexer = Lexer.init(src);
    defer lexer.deinit();

    // while (true) {
    //     const token = lexer.nextToken();
    //     std.log.info("{f}", .{token.data});
    //     if (token.data == .eof) break;
    // }

    const alloc = std.heap.smp_allocator;
    var parser: Parser = .{
        .alloc = alloc,
        .lexer = &lexer,
    };

    const expression = try parser.parseExpression(0);
    std.log.info("{f}", .{Parser.Expression.Formatter{ .parser = &parser, .expression = expression.value(&parser) }});

    if (expression.value(&parser).data != .err) {
        std.log.info("{}", .{eval(&parser, expression)});
    }
}

fn eval(parser: *Parser, expression: Parser.Expression.Handle) types.Int {
    return switch (expression.value(parser).data) {
        .lit => |lit| lit.int,
        .neg => |neg| -eval(parser, neg),
        .bin => |bin| {
            const left = eval(parser, bin.left);
            const right = eval(parser, bin.right);

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
