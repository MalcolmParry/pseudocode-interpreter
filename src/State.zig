const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

const State = @This();

alloc: std.mem.Allocator,
err_writer: *std.Io.Writer,
out_writer: *std.Io.Writer,
in_reader: *std.Io.Reader,
src: []const u8,
expressions: std.ArrayList(Parser.Expression) = .{},
statements: std.ArrayList(Parser.Statement) = .{},
code_blocks: std.ArrayList(Parser.CodeBlock) = .{},

pub fn deinit(this: *@This()) void {
    for (this.code_blocks.items) |*code_block| {
        this.alloc.free(code_block.statements);
    }

    for (this.statements.items) |*statement| {
        switch (statement.data) {
            .output => |output| this.alloc.free(output),
            else => {},
        }
    }

    this.expressions.deinit(this.alloc);
    this.statements.deinit(this.alloc);
    this.code_blocks.deinit(this.alloc);
    this.* = undefined;
}

pub fn logErr(this: *@This(), comptime fmt: []const u8, args: anytype) void {
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .red) catch @panic("color setting failed");
    this.err_writer.print("error: " ++ fmt ++ "\n", args) catch @panic("printing failed");
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .reset) catch @panic("color setting failed");
    this.err_writer.flush() catch @panic("cant flush");
}

pub fn expectToken(this: *@This(), expected: Lexer.Token.Type, got: Lexer.Token) !void {
    if (expected != got.t) {
        this.logErr("expected '{t}' got '{t}'", .{ expected, got.t });
        got.start.printToken(this);
        return error.Parser;
    }
}

pub fn unexpectedToken(this: *@This(), got: Lexer.Token) error{Parser} {
    this.logErr("unexpected token '{t}'", .{got.t});
    got.start.printToken(this);
    return error.Parser;
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

pub const types = struct {
    pub const Int = i64;
    pub const Real = f64;
};

pub const SourceLocation = struct {
    index: u32,

    pub fn tokenLength(this: @This(), state: *State) u16 {
        var lexer: Lexer = .{ .state = state, .loc = this };
        // token should have already been evaluated by the time this function is called
        _ = lexer.nextTokenInternal() catch unreachable;
        return @intCast(lexer.loc.index - this.index);
    }

    pub fn print(this: @This(), state: *State) void {
        const slice = SourceSlice{ .start = this.index, .len = 1 };
        slice.printWithUnderline(state);
    }

    pub fn printToken(this: @This(), state: *State) void {
        const slice = SourceSlice{ .start = this.index, .len = this.tokenLength(state) };
        slice.printWithUnderline(state);
    }

    pub const getInt = Lexer.getIntAt;
    pub const getReal = Lexer.getRealAt;
    pub const getString = Lexer.getStringAt;
    pub const getIdent = Lexer.getIdentAt;
};

pub const SourceSlice = struct {
    start: u32,
    len: u16,

    pub fn loc(this: @This()) SourceLocation {
        return .{
            .index = this.start,
        };
    }

    pub fn printWithUnderline(this: @This(), state: *State) void {
        std.debug.assert(this.start < state.src.len);

        const tty: std.Io.tty.Config = .escape_codes;

        var line_start: u32 = 0;
        for (state.src[0..this.start], 0..) |c, i| {
            if (c == '\n') line_start = @intCast(i + 1);
        }

        var line_len: u32 = 0;
        for (state.src[line_start..]) |c| {
            if (c == '\n') break;
            line_len += 1;
        }

        state.err_writer.print("{s}\n", .{state.src[line_start .. line_start + line_len]}) catch @panic("failed printing");
        for (state.src[line_start..this.start]) |c| {
            if (c == '\t') {
                state.err_writer.print("\t", .{}) catch @panic("failed printing");
            } else {
                state.err_writer.print(" ", .{}) catch @panic("failed printing");
            }
        }

        tty.setColor(state.err_writer, .green) catch @panic("failed to set color");
        state.err_writer.print("^", .{}) catch @panic("failed printing");
        for (0..this.len - 1) |_| state.err_writer.print("~", .{}) catch @panic("failed printing");
        state.err_writer.print("\n", .{}) catch @panic("failed printing");
        tty.setColor(state.err_writer, .reset) catch @panic("failed to set color");
        state.err_writer.flush() catch @panic("failed flushing");
    }
};
