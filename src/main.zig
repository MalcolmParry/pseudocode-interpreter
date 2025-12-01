const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const types = @import("types.zig");

const src: []const u8 = @embedFile("example.pseudo");

pub fn main() !void {
    var lexer = Lexer.init(src);

    // while (true) {
    //     const token = lexer.nextToken();
    //     std.log.info("{f}", .{token.data});
    //     if (token.data == .eof) break;
    // }

    lexer.index = 0;
    std.log.info("", .{});

    const alloc = std.heap.smp_allocator;
    var parser: Parser = .{
        .alloc = alloc,
        .lexer = &lexer,
    };

    const code_block = try parser.parseCodeBlock(.eof, 0);
    std.log.info("{f}", .{Parser.CodeBlock.Formatter{ .parser = &parser, .this = code_block }});

    // const statement = try parser.parseStatement();
    // std.log.info("{f}", .{Parser.Statement.Formatter{ .parser = &parser, .this = statement }});

    // const expression = try parser.parseExpression(0);
    // std.log.info("{f}", .{Parser.Expression.Formatter{ .parser = &parser, .this = expression }});
    //
    // if (expression.value(&parser).data != .err) {
    //     std.log.info("{}", .{eval(&parser, expression)});
    // }
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
