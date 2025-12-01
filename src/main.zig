const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Runner = @import("Runner.zig");
const types = @import("types.zig");

const src: []const u8 = @embedFile("example.pseudo");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var err_buffer: [64]u8 = undefined;
    const err_writer = std.debug.lockStderrWriter(&err_buffer);
    defer std.debug.unlockStderrWriter();

    var state: State = .{ .alloc = alloc, .src = src, .err_writer = err_writer };
    var lexer: Lexer = .{ .state = &state };

    try state.err_writer.print("=== TOKENS ===\n\n", .{});
    while (true) {
        const token = lexer.nextToken() catch |err| if (err != error.LexerError) return err else return;
        try err_writer.print("{f}\n", .{token.data});
        if (token.data == .eof) break;
    }
    try state.err_writer.flush();

    // lexer.index = 0;
    // std.log.info("\n\n\n", .{});
    //
    // var parser: Parser = .{
    //     .alloc = alloc,
    //     .lexer = &lexer,
    // };
    //
    // const code_block = try parser.parseCodeBlock(.eof, 0);
    // std.log.info("Code Block\n{f}", .{Parser.CodeBlock.Formatter{ .parser = &parser, .this = code_block }});
    //
    // var runner: Runner = .{
    //     .parser = &parser,
    //     .root = code_block,
    //     .alloc = alloc,
    // };
    //
    // var root_scope: Runner.Scope = .{
    //     .variables = .empty,
    //     .parent = null,
    // };
    // try runner.addRuntimePrimatives(&root_scope);
    //
    // const maybe_err = try runner.runCodeBlock(code_block, &root_scope);
    // if (maybe_err) |err|
    //     std.log.info("{s}", .{err.message});
}
