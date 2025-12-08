const std = @import("std");
const State = @import("State.zig");
const Lexer = @import("Lexer.zig");

const Parser = @This();

state: *State,
lexer: *Lexer,

pub fn parseCodeBlock(this: *@This(), ends: []const Lexer.Token.Type) error{ Lexer, Parser, OutOfMemory }!CodeBlock.Handle {
    var statements: std.ArrayList(Statement.Handle) = .{};
    errdefer statements.deinit(this.state.alloc);

    while (std.mem.indexOfScalar(Lexer.Token.Type, ends, (try this.lexer.peekToken()).t) == null) {
        const next = try this.parseStatement();
        try statements.append(this.state.alloc, next);
    }

    return this.state.newCodeBlock(.{
        .statements = statements,
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
                                .ident_loc = token.start,
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
                        .ident_loc = ident.start,
                        .type_loc = t.start,
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
                    .input = .{ .ident_loc = ident.start },
                },
            });
        },
        .for_ => {
            const assign = try this.parseStatement();
            if (assign.value(this.state).data != .assign) {
                this.state.logErr("expected assign statement", .{});
                return error.Parser;
            }
            const ident = assign.value(this.state).data.assign.ident_loc.getIdent(this.state);

            const to = try this.lexer.nextToken();
            try this.state.expectToken(.to, to);

            const expression = try this.parseExpression(0);
            const block = try this.parseCodeBlock(&.{.next});
            _ = this.lexer.nextToken() catch unreachable;

            const var_name = try this.lexer.nextToken();
            try this.state.expectToken(.ident, var_name);

            if (!std.mem.eql(u8, ident, var_name.start.getIdent(this.state))) {
                this.state.logErr("both identifiers to counter variable must be the same", .{});
                return error.Parser;
            }

            return this.state.newStatement(.{
                .data = .{
                    .for_ = .{
                        .assign = assign,
                        .limit = expression,
                        .block = block,
                    },
                },
            });
        },
        .repeat => {
            const block = try this.parseCodeBlock(&.{.until});
            try this.state.expectToken(.until, try this.lexer.nextToken());

            const condition = try this.parseExpression(0);

            return this.state.newStatement(.{
                .data = .{
                    .repeat_until = .{
                        .block = block,
                        .condition = condition,
                    },
                },
            });
        },
        .if_ => {
            const condition = try this.parseExpression(0);
            try this.state.expectToken(.then, try this.lexer.nextToken());
            const block = try this.parseCodeBlock(&.{ .endif, .else_ });
            const else_block: ?CodeBlock.Handle = blk: {
                if ((try this.lexer.nextToken()).t == .endif) break :blk null;

                const result = try this.parseCodeBlock(&.{.endif});
                _ = try this.lexer.nextToken();
                break :blk result;
            };

            return this.state.newStatement(.{
                .data = .{
                    .if_ = .{
                        .condition = condition,
                        .block = block,
                        .else_block = else_block,
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
    const start = left.value(this.state).src_slice.loc();

    while (true) {
        const op_tok = try this.lexer.peekToken();
        const op: BinaryOp.Op = switch (op_tok.t) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .eq => .eq,
            .not_eq => .not_eq,
            .more => .more,
            .less => .less,
            .more_eq => .more_eq,
            .less_eq => .less_eq,
            .and_ => .and_,
            .or_ => .or_,
            else => return left,
        };
        if (!op.canUse(order)) return left;
        _ = this.lexer.nextToken() catch unreachable;

        const right = try this.parseExpression(order + 1);

        left = try this.state.newExpression(.{
            .src_slice = .{
                .start = start.index,
                .len = @intCast(this.lexer.loc.index - start.index),
            },
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
                .src_slice = .{
                    .start = token.start.index,
                    .len = @intCast(this.lexer.loc.index - token.start.index),
                },
                .data = .{ .neg = expression },
            });
        },
        .lparen => {
            const expression = try this.parseExpression(0);

            const rparen = try this.lexer.nextToken();
            try this.state.expectToken(.rparen, rparen);

            expression.value(this.state).src_slice = .{
                .start = token.start.index,
                .len = @intCast(this.lexer.loc.index - token.start.index),
            };

            return expression;
        },
        .int => .int,
        .real => .real,
        .ident => .ident,
        .str => .str,
        else => return this.state.unexpectedToken(token),
    };

    return this.state.newExpression(.{
        .src_slice = .{
            .start = token.start.index,
            .len = @intCast(this.lexer.loc.index - token.start.index),
        },
        .data = data,
    });
}

const order_of_operation: [4][]const BinaryOp.Op = .{
    &.{
        .and_,
        .or_,
    },
    &.{
        .eq,
        .not_eq,
        .more,
        .less,
        .more_eq,
        .less_eq,
    },
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
        // arithmetic
        add,
        sub,
        mul,
        div,
        // relational
        eq,
        not_eq,
        more,
        less,
        more_eq,
        less_eq,
        // logical
        and_,
        or_,

        pub fn getSymbol(this: @This()) []const u8 {
            return switch (this) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .eq => "=",
                .not_eq => "!=",
                .more => ">",
                .less => "<",
                .more_eq => ">=",
                .less_eq => "<=",
                .and_ => "and",
                .or_ => "or",
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
    src_slice: State.SourceSlice,
    data: Data,

    pub const Data = union(enum) {
        ident,
        int,
        real,
        str,
        neg: Expression.Handle,
        // TODO: add not
        bin: BinaryOp,
    };

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            const expression = this.this.value(this.state);
            const loc = expression.src_slice.loc();

            switch (expression.data) {
                .int => try writer.print("{}", .{loc.getInt(this.state) catch return error.WriteFailed}),
                .real => try writer.print("{}f", .{loc.getReal(this.state) catch return error.WriteFailed}),
                .ident => try writer.print("@'{s}'", .{loc.getIdent(this.state)}),
                .str => {
                    const message = loc.getString(this.state) catch return error.WriteFailed;
                    defer this.state.alloc.free(message);
                    try writer.print("'{s}'", .{message});
                },
                .neg => |neg| try writer.print("-{f}", .{Formatter{ .state = this.state, .this = neg }}),
                .bin => |bin| try writer.print("({f} {s} {f})", .{
                    Formatter{ .state = this.state, .this = bin.left },
                    bin.op.getSymbol(),
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
        for_: ForLoop,
        repeat_until: RepeatUntil,
        if_: If,
    };

    pub const Input = struct {
        ident_loc: State.SourceLocation,
    };

    pub const Assign = struct {
        ident_loc: State.SourceLocation,
        value: Expression.Handle,
    };

    pub const Define = struct {
        ident_loc: State.SourceLocation,
        type_loc: State.SourceLocation,
    };

    pub const ForLoop = struct {
        assign: Handle,
        limit: Expression.Handle,
        block: CodeBlock.Handle,
    };

    pub const RepeatUntil = struct {
        condition: Expression.Handle,
        block: CodeBlock.Handle,
    };

    pub const If = struct {
        condition: Expression.Handle,
        block: CodeBlock.Handle,
        else_block: ?CodeBlock.Handle,
    };

    pub const Formatter = struct {
        state: *State,
        this: Handle,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.value(this.state).data) {
                .assign => |assign| try writer.print("set @'{s}' to ({f})", .{ assign.ident_loc.getIdent(this.state), Expression.Formatter{ .state = this.state, .this = assign.value } }),
                .define => |define| try writer.print("declare @'{s}' as @'{s}'", .{ define.ident_loc.getIdent(this.state), define.type_loc.getIdent(this.state) }),
                .output => |output| try writer.print("output {f}", .{Expression.ListFormatter{ .state = this.state, .this = output }}),
                .input => |input| try writer.print("input to @'{s}'", .{input.ident_loc.getIdent(this.state)}),
                .for_ => |for_| try writer.print("for {{{f}}} to {f}\n{f}", .{
                    Formatter{ .state = this.state, .this = for_.assign },
                    Expression.Formatter{ .state = this.state, .this = for_.limit },
                    CodeBlock.Formatter{ .state = this.state, .this = for_.block, .indent = 1 },
                }),
                .repeat_until => |repeat| try writer.print("repeat {f}\n{f}", .{
                    Expression.Formatter{ .state = this.state, .this = repeat.condition },
                    CodeBlock.Formatter{ .state = this.state, .this = repeat.block, .indent = 1 },
                }),
                .if_ => |if_| {
                    try writer.print("if {f}\n{f}", .{
                        Expression.Formatter{ .state = this.state, .this = if_.condition },
                        CodeBlock.Formatter{ .state = this.state, .this = if_.block, .indent = 1 },
                    });

                    if (if_.else_block) |else_block| try writer.print("else\n{f}", .{
                        CodeBlock.Formatter{ .state = this.state, .this = else_block, .indent = 1 },
                    });
                },
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
    statements: std.ArrayList(Statement.Handle),

    pub const Formatter = struct {
        state: *State,
        this: Handle,
        indent: u32 = 0,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            for (this.this.value(this.state).statements.items) |statement| {
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
