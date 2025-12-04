const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");

const Parser = @This();

state: *State,
lexer: *Lexer,

pub fn parseCodeBlock(this: *@This(), end: Lexer.Token.Type) error{ Lexer, Parser, OutOfMemory }!CodeBlock.Handle {
    var statements: std.ArrayList(Statement.Handle) = .{};
    errdefer statements.deinit(this.state.alloc);

    while ((try this.lexer.peekToken()).t != end) {
        const next = try this.parseStatement();
        try statements.append(this.state.alloc, next);
    }

    return this.state.newCodeBlock(.{
        .statements = statements.items,
    });
}

pub fn parseStatement(this: *@This()) !Statement.Handle {
    const token = try this.lexer.nextToken();

    switch (token.t) {
        .ident => {
            const token2 = try this.lexer.nextToken();

            switch (token2.t) {
                .assign => {
                    const expression = try this.parseExpression(0);

                    return this.state.newStatement(.{
                        .data = .{
                            .assign = .{
                                .ident_start = token.start,
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
                    .input = .{ .ident_start = ident.start },
                },
            });
        },
        .for_loop => {
            const assign = try this.parseStatement();
            if (assign.value(this.state).data != .assign) {
                this.state.logErr("expected assign statement", .{});
                return error.Parser;
            }
            const ident = Lexer.getIdentAt(this.state, assign.value(this.state).data.assign.ident_start);

            const to = try this.lexer.nextToken();
            try this.state.expectToken(.to, to);

            const expression = try this.parseExpression(0);
            const block = try this.parseCodeBlock(.next);
            _ = this.lexer.nextToken() catch unreachable;

            const var_name = try this.lexer.nextToken();
            try this.state.expectToken(.ident, var_name);

            if (!std.mem.eql(u8, ident, Lexer.getIdentAt(this.state, var_name.start))) {
                this.state.logErr("both identifiers to counter variable must be the same", .{});
                return error.Parser;
            }

            return this.state.newStatement(.{
                .data = .{
                    .for_loop = .{
                        .assign = assign,
                        .limit = expression,
                        .block = block,
                    },
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

        if ((try this.lexer.peekToken()).t != .comma) return result;
        _ = this.lexer.nextToken() catch unreachable;
    }
}

pub fn parseExpression(this: *@This(), order: usize) error{ OutOfMemory, Lexer, Parser }!Expression.Handle {
    if (order >= order_of_operation.len)
        return this.parseUnaryOp();

    var left = try this.parseExpression(order + 1);

    while (true) {
        const op_tok = try this.lexer.peekToken();
        const op: BinaryOp.Op = switch (op_tok.t) {
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

    const data: Expression.Data = switch (token.t) {
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
        .int => .{ .int = try Lexer.getIntAt(this.state, token.start) },
        .real => .{ .real = try Lexer.getRealAt(this.state, token.start) },
        .ident => .{ .ident = Lexer.getIdentAt(this.state, token.start) },
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
        for_loop: ForLoop,
    };

    pub const Input = struct {
        ident_start: u32,
    };

    pub const Assign = struct {
        ident_start: u32,
        value: Expression.Handle,
    };

    pub const Define = struct {
        ident_start: u32,
        type_start: u32,
    };

    pub const ForLoop = struct {
        assign: Handle,
        limit: Expression.Handle,
        block: CodeBlock.Handle,
    };

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .assign => |assign| try writer.print("set @'{s}' to ({f})", .{ Lexer.getIdentAt(this.state, assign.ident_start), Expression.Formatter{ .state = this.state, .this = assign.value } }),
                .define => |define| try writer.print("define @'{s}' as @'{s}'", .{ Lexer.getIdentAt(this.state, define.ident_start), Lexer.getIdentAt(this.state, define.type_start) }),
                .output => |output| try writer.print("output {f}", .{Expression.ListFormatter{ .state = this.state, .this = output }}),
                .input => |input| try writer.print("input to @'{s}'", .{Lexer.getIdentAt(this.state, input.ident_start)}),
                .for_loop => |for_loop| try writer.print("for {{{f}}} to {f}\n{f}", .{
                    Formatter{ .state = this.state, .this = for_loop.assign },
                    Expression.Formatter{ .state = this.state, .this = for_loop.limit },
                    CodeBlock.Formatter{ .state = this.state, .this = for_loop.block, .indent = 1 },
                }),
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

    pub const Formatter = struct {
        state: *State,
        this: Handle,
        indent: u32 = 0,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            for (this.this.value(this.state).statements) |statement| {
                for (0..this.indent) |_| try writer.print("    ", .{});

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
