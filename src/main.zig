const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Runner = @import("Runner.zig");

const src: []const u8 = @embedFile("example.pseudo");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var err_buffer: [64]u8 = undefined;
    const err_writer = std.debug.lockStderrWriter(&err_buffer);
    defer std.debug.unlockStderrWriter();
    var in_buffer: [256]u8 = undefined;
    var in_reader = std.fs.File.stdin().reader(&in_buffer);

    var state: State = .{
        .alloc = alloc,
        .src = src,
        .err_writer = err_writer,
        .out_writer = err_writer,
        .in_reader = &in_reader.interface,
    };

    var lexer: Lexer = .{ .state = &state };

    try state.err_writer.print("=== TOKENS ===\n", .{});
    while (true) {
        const token = lexer.nextToken() catch |err| if (err != error.Lexer) return err else return;
        try err_writer.print("{f}\n", .{Lexer.Token.Formatter{ .state = &state, .this = token }});
        if (token.t == .eof) break;
    }
    try state.err_writer.flush();

    lexer.loc.index = 0;
    try state.err_writer.print("\n=== AST ===\n", .{});

    var parser: Parser = .{
        .state = &state,
        .lexer = &lexer,
    };

    const code_block = parser.parseCodeBlock(&.{.eof}) catch |err| if (err != error.Parser) return err else return;
    try state.err_writer.print("{f}", .{Parser.CodeBlock.Formatter{ .state = &state, .this = code_block }});
    try state.err_writer.flush();

    var runner: Runner = .{
        .state = &state,
        .parser = &parser,
    };

    var root_scope: Runner.Scope = .{
        .variables = .empty,
        .parent = null,
    };
    try runner.addRuntimePrimatives(&root_scope);

    try state.err_writer.print("\n=== RUNNER ===\n", .{});
    try state.err_writer.flush();
    runner.runCodeBlock(code_block, &root_scope) catch |err| if (err != error.Runtime) return err else return;
}
