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
        neg: *Expression,
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
    const left = try parseUnaryOp(lexer, alloc);
    errdefer alloc.destroy(left);
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

    const loc: SourceLocation = .{
        .line = left.loc.line,
        .col = left.loc.col,
        .len = left.loc.len, // TODO: do whole thing
    };

    result.* = .{
        .loc = loc,
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

pub fn parseUnaryOp(lexer: *Lexer, alloc: std.mem.Allocator) error{OutOfMemory}!*Expression {
    const token = lexer.nextTokenNoWS();

    const data: Expression.Data = switch (token.data) {
        .sub => {
            const expression = try parseUnaryOp(lexer, alloc);
            if (expression.data == .err) return expression;

            const result = try alloc.create(Expression);
            result.* = .{
                .loc = .{
                    .line = token.loc.line,
                    .col = token.loc.col,
                    .len = expression.loc.len + token.loc.len,
                },
                .data = .{ .neg = expression },
            };

            return result;
        },
        .lparen => {
            const expression = try parseExpression(lexer, alloc);
            if (expression.data == .err) return expression;
            const rparen = lexer.nextTokenNoWS();

            if (rparen.data != .rparen) {
                const result = try alloc.create(Expression);
                result.* = .{
                    .loc = rparen.loc,
                    .data = .{
                        .err = "expected )",
                    },
                };

                return result;
            }

            return expression;
        },
        .err => |err| {
            const result = try alloc.create(Expression);
            result.* = .{
                .loc = token.loc,
                .data = .{ .err = err },
            };

            return result;
        },
        .int, .float => .{ .lit = token.data },
        else => .{
            .err = "unexpected token",
        },
    };

    const result = try alloc.create(Expression);
    result.* = .{
        .loc = token.loc,
        .data = data,
    };

    return result;
}
