const std = @import("std");
const Lexer = @import("Lexer.zig");
const types = @import("types.zig");

const Parser = @This();

lexer: *Lexer,
expressions: std.ArrayList(Expression) = .{},
statements: std.ArrayList(Statement) = .{},
code_blocks: std.ArrayList(CodeBlock) = .{},
alloc: std.mem.Allocator,

pub fn parseCodeBlock(this: *@This(), end: Lexer.Token.Data.Tag, start: u32) !CodeBlock.Handle {
    var statements: std.ArrayList(Statement.Handle) = .{};
    errdefer statements.deinit(this.alloc);

    while (this.lexer.peekToken().data != end) {
        const next = try this.parseStatement();

        if (next.value(this).data == .err) {
            statements.deinit(this.alloc);

            return this.newCodeBlock(.{
                .start = next.value(this).start,
                .statements = &.{next},
            });
        }

        try statements.append(this.alloc, next);
    }

    return this.newCodeBlock(.{
        .start = start,
        .statements = statements.items,
    });
}

pub fn parseStatement(this: *@This()) !Statement.Handle {
    const token = this.lexer.nextToken();

    switch (token.data) {
        .ident => |ident| {
            const token2 = this.lexer.peekToken();

            switch (token2.data) {
                .assign => {
                    _ = this.lexer.nextToken();
                    const expression = try this.parseExpression(0);
                    if (expression.value(this).data == .err) {
                        return this.newStatement(.{
                            .start = expression.value(this).start,
                            .data = .{
                                .err = expression.value(this).data.err,
                            },
                        });
                    }

                    return this.newStatement(.{
                        .start = token.start,
                        .data = .{
                            .assign = .{
                                .ident = ident,
                                .value = expression,
                            },
                        },
                    });
                },
                else => return this.errorStatement(token.start, "unexpected token"),
            }
        },
        .define => {
            const ident = this.lexer.nextToken();
            if (ident.data != .ident)
                return this.errorStatement(token.start, "expected identifier");

            if (this.lexer.nextToken().data != .colon)
                return this.errorStatement(token.start, "expected colon");

            const t = this.lexer.nextToken();
            if (t.data != .ident)
                return this.errorStatement(t.start, "expected type identifier");

            return this.newStatement(.{
                .start = token.start,
                .data = .{
                    .define = .{
                        .ident = ident.data.ident,
                        .t = t.data.ident,
                    },
                },
            });
        },
        .output => {
            const expression = try this.parseExpression(0);
            if (expression.value(this).data == .err) return this.errorStatement(expression.value(this).start, expression.value(this).data.err);

            return this.newStatement(.{
                .start = token.start,
                .data = .{
                    .output = expression,
                },
            });
        },
        .err => |err| return this.errorStatement(token.start, err),
        else => return this.errorStatement(token.start, "unexpected token"),
    }
}

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

            if (rparen.data != .rparen) return this.errorExpression(rparen.start, "expected )");

            return expression;
        },
        .err => |err| {
            return this.newExpression(.{
                .start = token.start,
                .data = .{ .err = err },
            });
        },
        .int, .real, .ident => .{ .lit = token.data },
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

pub fn newStatement(this: *@This(), new: Statement) !Statement.Handle {
    try this.statements.append(this.alloc, new);
    return @enumFromInt(this.statements.items.len - 1);
}

pub fn newCodeBlock(this: *@This(), new: CodeBlock) !CodeBlock.Handle {
    try this.code_blocks.append(this.alloc, new);
    return @enumFromInt(this.code_blocks.items.len - 1);
}

pub fn errorExpression(this: *@This(), start: u32, err: []const u8) !Expression.Handle {
    return newExpression(this, .{
        .start = start,
        .data = .{
            .err = err,
        },
    });
}

pub fn errorStatement(this: *@This(), start: u32, err: []const u8) !Statement.Handle {
    return newStatement(this, .{
        .start = start,
        .data = .{
            .err = err,
        },
    });
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
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        lit: Lexer.Token.Data,
        neg: Expression.Handle,
        bin: BinaryOp,
        err: []const u8,
    };

    pub const Formatter = struct {
        parser: *Parser,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.parser).data) {
                .lit => |lit| try writer.print("{f}", .{lit}),
                .neg => |neg| try writer.print("-{f}", .{Formatter{ .parser = this.parser, .this = neg }}),
                .bin => |bin| try writer.print("({f} {c} {f})", .{
                    Formatter{ .parser = this.parser, .this = bin.left },
                    bin.op.getChar(),
                    Formatter{ .parser = this.parser, .this = bin.right },
                }),
                .err => |err| try writer.print("parser error: {s}", .{err}),
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), parser: *Parser) *Expression {
            return &parser.expressions.items[@intFromEnum(handle)];
        }
    };
};

pub const Statement = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        assign: Assign,
        define: Define,
        output: Expression.Handle,
        err: []const u8,
    };

    pub const Assign = struct {
        ident: []const u8,
        value: Expression.Handle,
    };

    pub const Define = struct {
        ident: []const u8,
        t: []const u8,
    };

    pub const Formatter = struct {
        parser: *Parser,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.parser).data) {
                .assign => |assign| try writer.print("set @'{s}' to ({f})", .{ assign.ident, Expression.Formatter{ .parser = this.parser, .this = assign.value } }),
                .define => |define| try writer.print("define @'{s}' as @'{s}'", .{ define.ident, define.t }),
                .output => |output| try writer.print("ouput {f}", .{Expression.Formatter{ .parser = this.parser, .this = output }}),
                .err => |err| try writer.print("parser error: {s}", .{err}),
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), parser: *Parser) *Statement {
            return &parser.statements.items[@intFromEnum(handle)];
        }
    };
};

pub const CodeBlock = struct {
    statements: []const Statement.Handle,
    start: u32,

    pub const Formatter = struct {
        parser: *Parser,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            for (this.this.value(this.parser).statements) |statement| {
                try writer.print("{f}\n", .{Statement.Formatter{ .parser = this.parser, .this = statement }});
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), parser: *Parser) *CodeBlock {
            return &parser.code_blocks.items[@intFromEnum(handle)];
        }
    };
};
