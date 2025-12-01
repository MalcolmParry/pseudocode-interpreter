const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Runner = @import("Runner.zig");
const types = @import("types.zig");

const src: []const u8 = @embedFile("example.pseudo");

pub fn main() !void {
    var lexer = Lexer.init(src);

    while (true) {
        const token = lexer.nextToken();
        std.log.info("{f}", .{token.data});
        if (token.data == .eof) break;
    }

    lexer.index = 0;
    std.log.info("\n\n\n", .{});

    const alloc = std.heap.smp_allocator;
    var parser: Parser = .{
        .alloc = alloc,
        .lexer = &lexer,
    };

    const code_block = try parser.parseCodeBlock(.eof, 0);
    std.log.info("Code Block\n{f}", .{Parser.CodeBlock.Formatter{ .parser = &parser, .this = code_block }});

    var runner: Runner = .{
        .parser = &parser,
        .root = code_block,
        .alloc = alloc,
    };

    var root_scope: Runner.Scope = .{
        .variables = .empty,
        .parent = null,
    };
    try runner.addRuntimePrimatives(&root_scope);

    const maybe_err = try runner.runCodeBlock(code_block, &root_scope);
    if (maybe_err) |err|
        std.log.info("{s}", .{err.message});
}
