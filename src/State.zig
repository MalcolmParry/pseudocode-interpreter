const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

alloc: std.mem.Allocator,
err_writer: *std.Io.Writer,
src: []const u8,
expressions: std.ArrayList(Parser.Expression) = .{},
statements: std.ArrayList(Parser.Statement) = .{},
code_blocks: std.ArrayList(Parser.CodeBlock) = .{},

pub fn logErr(this: *@This(), comptime fmt: []const u8, args: anytype) void {
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .red) catch @panic("color setting failed");
    this.err_writer.print("error: " ++ fmt ++ "\n", args) catch @panic("printing failed");
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .reset) catch @panic("color setting failed");
    this.err_writer.flush() catch @panic("cant flush");
}

pub fn srcLoc(this: *@This(), start: u32, len: u32) void {
    std.debug.assert(start < this.src.len);

    const tty: std.Io.tty.Config = .escape_codes;

    var line_start: u32 = 0;
    for (this.src[0..start], 0..) |c, i| {
        if (c == '\n') line_start = @intCast(i + 1);
    }

    var line_len: u32 = 0;
    for (this.src[line_start..]) |c| {
        if (c == '\n') break;
        line_len += 1;
    }

    this.err_writer.print("{s}\n", .{this.src[line_start .. line_start + line_len]}) catch @panic("failed printing");
    for (0..start - line_start) |_| this.err_writer.print(" ", .{}) catch @panic("failed printing");

    tty.setColor(this.err_writer, .green) catch @panic("failed to set color");
    this.err_writer.print("^", .{}) catch @panic("failed printing");
    for (0..len - 1) |_| this.err_writer.print("~", .{}) catch @panic("failed printing");
    this.err_writer.print("\n", .{}) catch @panic("failed printing");
    tty.setColor(this.err_writer, .reset) catch @panic("failed to set color");
    this.err_writer.flush() catch @panic("failed flushing");
}

pub fn expectToken(this: *@This(), expected: Lexer.Token.Data.Tag, got: Lexer.Token) !void {
    if (expected != got.data) {
        this.logErr("expected '{t}' got '{t}'", .{ expected, got.data });
        this.srcLoc(got.start, this.tokenLengthAt(got.start));
        return error.Parser;
    }
}

pub fn unexpectedToken(this: *@This(), got: Lexer.Token) error{Parser} {
    this.logErr("unexpected token '{t}'", .{got.data});
    this.srcLoc(got.start, this.tokenLengthAt(got.start));
    return error.Parser;
}

pub fn tokenLengthAt(this: *@This(), start: u32) u32 {
    var lexer: Lexer = .{ .state = this, .index = start };
    // token should have already been evaluated by the time this function is called
    _ = lexer.nextTokenInternal() catch unreachable;
    return lexer.index - start;
}

pub fn newExpression(this: *@This(), new: Parser.Expression) !Parser.Expression.Handle {
    try this.expressions.append(this.alloc, new);
    return @enumFromInt(this.expressions.items.len - 1);
}

pub fn newStatement(this: *@This(), new: Parser.Statement) !Parser.Statement.Handle {
    try this.statements.append(this.alloc, new);
    return @enumFromInt(this.statements.items.len - 1);
}

pub fn newCodeBlock(this: *@This(), new: Parser.CodeBlock) !Parser.CodeBlock.Handle {
    try this.code_blocks.append(this.alloc, new);
    return @enumFromInt(this.code_blocks.items.len - 1);
}

pub fn errorExpression(this: *@This(), start: u32, err: []const u8) !Parser.Expression.Handle {
    return newExpression(this, .{
        .start = start,
        .data = .{
            .err = err,
        },
    });
}

pub fn errorStatement(this: *@This(), start: u32, err: []const u8) !Parser.Statement.Handle {
    return newStatement(this, .{
        .start = start,
        .data = .{
            .err = err,
        },
    });
}
