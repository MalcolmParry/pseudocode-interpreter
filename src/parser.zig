const std = @import("std");
const Lexer = @import("Lexer.zig");
const SourceLocation = @import("SourceLocation.zig");
const types = @import("types.zig");

pub const BinaryOp = struct {
    pub const Op = enum {
        add,
        sub,
        mul,
        div,

        pub fn getChar(this: @This()) u8 {
            return switch (this) {
                .add => '+',
                .sub => '-',
                .mul => '*',
                .div => '/',
            };
        }
    };

    left: *Expression,
    right: *Expression,
    op: Op,
};

pub const Expression = struct {
    pub const Data = union(enum) {
        lit: Lexer.Token.Data,
        neg: Lexer.Token.Data,
        bin: BinaryOp,
        err: []const u8,
    };

    loc: SourceLocation,
    data: Data,

    pub fn format(this: *@This(), writer: *std.Io.Writer) !void {
        switch (this.data) {
            .lit => |lit| try writer.print("{f}", .{lit}),
            .neg => |neg| try writer.print("-{f}", .{neg}),
            .bin => |bin| try writer.print("({f} {c} {f})", .{ bin.left, bin.op.getChar(), bin.right }),
            .err => |err| try writer.print("parser error: {s}", .{err}),
        }
    }
};

pub fn parseExpression(lexer: *Lexer, alloc: std.mem.Allocator) error{OutOfMemory}!*Expression {
    const left = try alloc.create(Expression);
    errdefer alloc.destroy(left);
    left.* = parseUnaryOp(lexer);
    if (left.data == .err) return left;

    const op_tok = lexer.peekTokenNoWS();
    const op: BinaryOp.Op = switch (op_tok.data) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        else => return left,
    };
    _ = lexer.nextTokenNoWS();

    const right = try parseExpression(lexer, alloc);
    errdefer alloc.destroy(right);
    if (right.data == .err) return right;

    const result = try alloc.create(Expression);
    errdefer alloc.destroy(result);
    result.* = .{
        .loc = .{
            .line = left.loc.line,
            .col = left.loc.col,
            .len = left.loc.len, // TODO: do whole thing
        },
        .data = .{
            .bin = .{
                .left = left,
                .right = right,
                .op = op,
            },
        },
    };

    return result;
}

pub fn parseUnaryOp(lexer: *Lexer) Expression {
    var token = lexer.nextTokenNoWS();
    var minus: bool = false;
    if (token.data == .sub) {
        minus = true;
        token = lexer.nextTokenNoWS();
    }

    if (!Lexer.Token.Data.isLiteral(token.data)) {
        if (token.data == .err) return .{
            .loc = token.loc,
            .data = .{ .err = token.data.err },
        };
    }

    const data: Expression.Data = blk: switch (token.data) {
        .int, .float => {
            if (minus)
                break :blk .{ .neg = token.data };

            break :blk .{ .lit = token.data };
        },
        else => .{
            .err = "unexpected token",
        },
    };

    return .{
        .loc = token.loc,
        .data = data,
    };
}
