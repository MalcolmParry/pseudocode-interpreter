const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");
const types = @import("types.zig");

const Parser = @This();

state: *State,
lexer: *Lexer,

pub fn parseCodeBlock(this: *@This(), end: Lexer.Token.Data.Tag, start: u32) !CodeBlock.Handle {
    var statements: std.ArrayList(Statement.Handle) = .{};
    errdefer statements.deinit(this.state.alloc);

    while ((try this.lexer.peekToken()).data != end) {
        const next = try this.parseStatement();

        if (next.value(this.state).data == .err) {
            statements.deinit(this.state.alloc);

            return this.state.newCodeBlock(.{
                .start = next.value(this.state).start,
                .statements = &.{next},
            });
        }

        try statements.append(this.state.alloc, next);
    }

    return this.state.newCodeBlock(.{
        .start = start,
        .statements = statements.items,
    });
}

pub fn parseStatement(this: *@This()) !Statement.Handle {
    const token = try this.lexer.nextToken();

    switch (token.data) {
        .ident => |ident| {
            const token2 = try this.lexer.nextToken();

            switch (token2.data) {
                .assign => {
                    const expression = try this.parseExpression(0);
                    if (expression.value(this.state).data == .err) {
                        return this.state.newStatement(.{
                            .start = expression.value(this.state).start,
                            .data = .{
                                .err = expression.value(this.state).data.err,
                            },
                        });
                    }

                    return this.state.newStatement(.{
                        .start = token.start,
                        .data = .{
                            .assign = .{
                                .ident = ident,
                                .value = expression,
                            },
                        },
                    });
                },
                else => return this.state.errorStatement(token.start, "unexpected token"),
            }
        },
        .define => {
            const ident = try this.lexer.nextToken();
            if (ident.data != .ident)
                return this.state.errorStatement(token.start, "expected identifier");

            if ((try this.lexer.nextToken()).data != .colon)
                return this.state.errorStatement(token.start, "expected colon");

            const t = try this.lexer.nextToken();
            if (t.data != .ident)
                return this.state.errorStatement(t.start, "expected type identifier");

            return this.state.newStatement(.{
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
            if (expression.value(this.state).data == .err) return this.state.errorStatement(expression.value(this.state).start, expression.value(this.state).data.err);

            return this.state.newStatement(.{
                .start = token.start,
                .data = .{
                    .output = expression,
                },
            });
        },
        else => return this.state.errorStatement(token.start, "unexpected token"),
    }
}

pub fn parseExpression(this: *@This(), order: usize) error{ OutOfMemory, Lexer }!Expression.Handle {
    if (order >= order_of_operation.len)
        return this.parseUnaryOp();

    var left = try this.parseExpression(order + 1);
    if (left.value(this.state).data == .err) return left;

    while (true) {
        const op_tok = try this.lexer.peekToken();
        const op: BinaryOp.Op = switch (op_tok.data) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            else => return left,
        };
        if (!op.canUse(order)) return left;
        _ = this.lexer.nextToken() catch unreachable;

        const right = try this.parseExpression(order + 1);
        if (right.value(this.state).data == .err) return right;

        left = try this.state.newExpression(.{
            .start = left.value(this.state).start,
            .data = .{ .bin = .{
                .left = left,
                .right = right,
                .op = op,
            } },
        });
    }
}

pub fn parseUnaryOp(this: *@This()) !Expression.Handle {
    const token = try this.lexer.nextToken();

    const data: Expression.Data = switch (token.data) {
        .sub => {
            const expression = try this.parseUnaryOp();
            if (expression.value(this.state).data == .err) return expression;

            return this.state.newExpression(.{
                .start = token.start,
                .data = .{ .neg = expression },
            });
        },
        .lparen => {
            const expression = try this.parseExpression(0);
            if (expression.value(this.state).data == .err) return expression;
            expression.value(this.state).start = token.start;
            const rparen = try this.lexer.nextToken();

            if (rparen.data != .rparen) return this.state.errorExpression(rparen.start, "expected )");

            return expression;
        },
        .int, .real, .ident => .{ .lit = token.data },
        else => .{
            .err = "unexpected token",
        },
    };

    return this.state.newExpression(.{
        .start = token.start,
        .data = data,
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
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .lit => |lit| try writer.print("{f}", .{lit}),
                .neg => |neg| try writer.print("-{f}", .{Formatter{ .state = this.state, .this = neg }}),
                .bin => |bin| try writer.print("({f} {c} {f})", .{
                    Formatter{ .state = this.state, .this = bin.left },
                    bin.op.getChar(),
                    Formatter{ .state = this.state, .this = bin.right },
                }),
                .err => |err| try writer.print("parser error: {s}", .{err}),
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), state: *State) *Expression {
            return &state.expressions.items[@intFromEnum(handle)];
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
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .assign => |assign| try writer.print("set @'{s}' to ({f})", .{ assign.ident, Expression.Formatter{ .state = this.state, .this = assign.value } }),
                .define => |define| try writer.print("define @'{s}' as @'{s}'", .{ define.ident, define.t }),
                .output => |output| try writer.print("ouput {f}", .{Expression.Formatter{ .state = this.state, .this = output }}),
                .err => |err| try writer.print("parser error: {s}", .{err}),
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), state: *State) *Statement {
            return &state.statements.items[@intFromEnum(handle)];
        }
    };
};

pub const CodeBlock = struct {
    statements: []const Statement.Handle,
    start: u32,

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            for (this.this.value(this.state).statements) |statement| {
                try writer.print("{f}\n", .{Statement.Formatter{ .state = this.state, .this = statement }});
            }
        }
    };

    pub const Handle = enum(u32) {
        _,

        pub fn value(handle: @This(), state: *State) *CodeBlock {
            return &state.code_blocks.items[@intFromEnum(handle)];
        }
    };
};
