const std = @import("std");
const Lexer = @import("Lexer.zig");
const types = @import("types.zig");

const order_of_operation: [2][]const BinaryOp.Op = .{
    &.{
        .add,
        .sub,
    },
    &.{
        .mul,
        .div,
    },
};

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

        pub fn canUse(this: @This(), order: usize) bool {
            return std.mem.indexOfScalar(BinaryOp.Op, order_of_operation[order], this) != null;
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

    start: u32,
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

pub fn parseExpression(lexer: *Lexer, order: usize, alloc: std.mem.Allocator) error{OutOfMemory}!*Expression {
    if (order >= order_of_operation.len)
        return parseUnaryOp(lexer, alloc);

    var left = try parseExpression(lexer, order + 1, alloc);
    errdefer alloc.destroy(left);
    if (left.data == .err) return left;

    while (true) {
        const op_tok = lexer.peekToken();
        const op: BinaryOp.Op = switch (op_tok.data) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            else => return left,
        };
        if (!op.canUse(order)) return left;
        _ = lexer.nextToken();

        const right = try parseExpression(lexer, order + 1, alloc);
        errdefer alloc.destroy(right);
        if (right.data == .err) return right;

        const new = try alloc.create(Expression);
        new.* = .{
            .start = left.start,
            .data = .{ .bin = .{
                .left = left,
                .right = right,
                .op = op,
            } },
        };
        left = new;
    }
}

pub fn parseUnaryOp(lexer: *Lexer, alloc: std.mem.Allocator) error{OutOfMemory}!*Expression {
    const token = lexer.nextToken();

    const data: Expression.Data = switch (token.data) {
        .sub => {
            const expression = try parseUnaryOp(lexer, alloc);
            if (expression.data == .err) return expression;

            const result = try alloc.create(Expression);
            result.* = .{
                .start = token.start,
                .data = .{ .neg = expression },
            };

            return result;
        },
        .lparen => {
            const expression = try parseExpression(lexer, 0, alloc);
            if (expression.data == .err) return expression;
            expression.start = token.start;
            const rparen = lexer.nextToken();

            if (rparen.data != .rparen) {
                const result = try alloc.create(Expression);
                result.* = .{
                    .start = rparen.start,
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
                .start = token.start,
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
        .start = token.start,
        .data = data,
    };

    return result;
}
