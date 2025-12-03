const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");

const Parser = @This();

state: *State,
lexer: *Lexer,

pub fn parseCodeBlock(this: *@This(), end: Lexer.Token.Data.Tag, start: u32) !CodeBlock.Handle {
    var statements: std.ArrayList(Statement.Handle) = .{};
    errdefer statements.deinit(this.state.alloc);

    while ((try this.lexer.peekToken()).data != end) {
        const next = try this.parseStatement();
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

                    return this.state.newStatement(.{
                        .data = .{
                            .assign = .{
                                .ident = ident,
                                .value = expression,
                            },
                        },
                    });
                },
                else => return this.state.unexpectedToken(token2),
            }
        },
        .declare => {
            const ident = try this.lexer.nextToken();
            try this.state.expectToken(.ident, ident);

            const colon = try this.lexer.nextToken();
            try this.state.expectToken(.colon, colon);

            const t = try this.lexer.nextToken();
            try this.state.expectToken(.ident, t);

            return this.state.newStatement(.{
                .data = .{
                    .define = .{
                        .ident_start = ident.start,
                        .type_start = t.start,
                        .ident = ident.data.ident,
                        .t = t.data.ident,
                    },
                },
            });
        },
        .output => {
            const expression_list = try this.parseExpressionList();

            return this.state.newStatement(.{
                .data = .{
                    .output = expression_list,
                },
            });
        },
        .input => {
            const ident = try this.lexer.nextToken();
            try this.state.expectToken(.ident, ident);

            return this.state.newStatement(.{
                .data = .{
                    .input = .{ .ident = ident.data.ident },
                },
            });
        },
        else => return this.state.unexpectedToken(token),
    }
}

pub fn parseExpressionList(this: *@This()) !std.ArrayList(Expression.Handle) {
    var result: std.ArrayList(Expression.Handle) = .empty;

    while (true) {
        try result.append(this.state.alloc, try this.parseExpression(0));

        if ((try this.lexer.peekToken()).data != .comma) return result;
        _ = this.lexer.nextToken() catch unreachable;
    }
}

pub fn parseExpression(this: *@This(), order: usize) error{ OutOfMemory, Lexer, Parser }!Expression.Handle {
    if (order >= order_of_operation.len)
        return this.parseUnaryOp();

    var left = try this.parseExpression(order + 1);

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

pub fn parseUnaryOp(this: *@This()) error{ OutOfMemory, Lexer, Parser }!Expression.Handle {
    const token = try this.lexer.nextToken();

    const data: Expression.Data = switch (token.data) {
        .sub => {
            const expression = try this.parseUnaryOp();

            return this.state.newExpression(.{
                .start = token.start,
                .data = .{ .neg = expression },
            });
        },
        .lparen => {
            const expression = try this.parseExpression(0);
            expression.value(this.state).start = token.start;

            const rparen = try this.lexer.nextToken();
            try this.state.expectToken(.rparen, rparen);

            return expression;
        },
        .int => |int| .{ .int = int },
        .real => |real| .{ .real = real },
        .ident => |ident| .{ .ident = ident },
        .str => .{ .str = .{ .start = token.start } },
        else => return this.state.unexpectedToken(token),
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
        ident: []const u8,
        int: State.types.Int,
        real: State.types.Real,
        str: struct {
            start: u32,
        },
        neg: Expression.Handle,
        bin: BinaryOp,
    };

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .int => |int| try writer.print("{}", .{int}),
                .real => |real| try writer.print("{}f", .{real}),
                .str => |str| {
                    const message = Lexer.getStringAt(this.state, str.start) catch return error.WriteFailed;
                    defer this.state.alloc.free(message);
                    try writer.print("'{s}'", .{message});
                },
                .ident => |ident| try writer.print("@'{s}'", .{ident}),
                .neg => |neg| try writer.print("-{f}", .{Formatter{ .state = this.state, .this = neg }}),
                .bin => |bin| try writer.print("({f} {c} {f})", .{
                    Formatter{ .state = this.state, .this = bin.left },
                    bin.op.getChar(),
                    Formatter{ .state = this.state, .this = bin.right },
                }),
            }
        }
    };

    pub const ListFormatter = struct {
        state: *State,
        this: std.ArrayList(Handle),

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            for (this.this.items, 0..) |expression, i| {
                if (i != 0) try writer.print(", ", .{});
                try writer.print("{f}", .{Formatter{ .state = this.state, .this = expression }});
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
    data: Data,

    pub const Data = union(enum) {
        assign: Assign,
        define: Define,
        output: std.ArrayList(Expression.Handle),
        input: Input,
    };

    pub const Input = struct {
        ident: []const u8,
    };

    pub const Assign = struct {
        ident: []const u8,
        value: Expression.Handle,
    };

    pub const Define = struct {
        ident: []const u8,
        t: []const u8,
        ident_start: u32,
        type_start: u32,
    };

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .assign => |assign| try writer.print("set @'{s}' to ({f})", .{ assign.ident, Expression.Formatter{ .state = this.state, .this = assign.value } }),
                .define => |define| try writer.print("define @'{s}' as @'{s}'", .{ define.ident, define.t }),
                .output => |output| try writer.print("output {f}", .{Expression.ListFormatter{ .state = this.state, .this = output }}),
                .input => |input| try writer.print("input to @'{s}'", .{input.ident}),
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
