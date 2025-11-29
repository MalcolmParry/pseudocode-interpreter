const std = @import("std");
const Lexer = @import("Lexer.zig");
const types = @import("types.zig");

const Parser = @This();

lexer: *Lexer,
expressions: std.ArrayList(Expression) = .{},
alloc: std.mem.Allocator,

pub fn parseExpression(this: *@This(), order: usize) error{OutOfMemory}!Expression.Handle {
    if (order >= order_of_operation.len)
        return this.parseUnaryOp();

    var left = try this.parseExpression(order + 1);
    if (left.value(this).data == .err) return left;

    while (true) {
        const op_tok = this.lexer.peekToken();
        const op: BinaryOp.Op = switch (op_tok.data) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            else => return left,
        };
        if (!op.canUse(order)) return left;
        _ = this.lexer.nextToken();

        const right = try this.parseExpression(order + 1);
        if (right.value(this).data == .err) return right;

        left = try this.newExpression(.{
            .start = left.value(this).start,
            .data = .{ .bin = .{
                .left = left,
                .right = right,
                .op = op,
            } },
        });
    }
}

pub fn parseUnaryOp(this: *@This()) !Expression.Handle {
    const token = this.lexer.nextToken();

    const data: Expression.Data = switch (token.data) {
        .sub => {
            const expression = try this.parseUnaryOp();
            if (expression.value(this).data == .err) return expression;

            return this.newExpression(.{
                .start = token.start,
                .data = .{ .neg = expression },
            });
        },
        .lparen => {
            const expression = try this.parseExpression(0);
            if (expression.value(this).data == .err) return expression;
            expression.value(this).start = token.start;
            const rparen = this.lexer.nextToken();

            if (rparen.data != .rparen) {
                return this.newExpression(.{
                    .start = rparen.start,
                    .data = .{
                        .err = "expected )",
                    },
                });
            }

            return expression;
        },
        .err => |err| {
            return this.newExpression(.{
                .start = token.start,
                .data = .{ .err = err },
            });
        },
        .int, .float => .{ .lit = token.data },
        else => .{
            .err = "unexpected token",
        },
    };

    return this.newExpression(.{
        .start = token.start,
        .data = data,
    });
}

pub fn newExpression(this: *@This(), new: Expression) !Expression.Handle {
    try this.expressions.append(this.alloc, new);
    return @enumFromInt(this.expressions.items.len - 1);
}

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

    left: Expression.Handle,
    right: Expression.Handle,
    op: Op,
};

pub const Expression = struct {
    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), parser: *Parser) *Expression {
            return &parser.expressions.items[@intFromEnum(handle)];
        }
    };

    pub const Data = union(enum) {
        lit: Lexer.Token.Data,
        neg: Expression.Handle,
        bin: BinaryOp,
        err: []const u8,
    };

    start: u32,
    data: Data,

    pub const Formatter = struct {
        parser: *Parser,
        expression: *Expression,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.expression.data) {
                .lit => |lit| try writer.print("{f}", .{lit}),
                .neg => |neg| try writer.print("-{f}", .{Formatter{ .parser = this.parser, .expression = neg.value(this.parser) }}),
                .bin => |bin| try writer.print("({f} {c} {f})", .{
                    Formatter{ .parser = this.parser, .expression = bin.left.value(this.parser) },
                    bin.op.getChar(),
                    Formatter{ .parser = this.parser, .expression = bin.right.value(this.parser) },
                }),
                .err => |err| try writer.print("parser error: {s}", .{err}),
            }
        }
    };
};
