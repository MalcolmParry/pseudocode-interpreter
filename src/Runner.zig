const std = @import("std");
const builtin = @import("builtin");
const State = @import("State.zig");
const Parser = @import("Parser.zig");
const Lexer = @import("Lexer.zig");

const Runner = @This();
const Error = error{ OutOfMemory, Runtime, WriteFailed, ReadFailed, StreamTooLong, EndOfStream };

state: *State,
parser: *Parser,

pub fn runCodeBlock(this: *@This(), block: Parser.CodeBlock.Handle, parent_scope: ?*Scope) !void {
    var scope: Scope = .{
        .variables = .empty,
        .parent = parent_scope,
    };

    for (block.value(this.state).statements) |statement_handle| {
        try runStatement(this, &scope, statement_handle);
    }
}

pub fn runStatement(this: *@This(), scope: *Scope, statement_handle: Parser.Statement.Handle) Error!void {
    const statement = statement_handle.value(this.state);

    switch (statement.data) {
        .define => |define| {
            if (scope.variables.contains(define.ident)) {
                this.state.logErr("variable '{s}' already defined", .{define.ident});
                this.state.srcLoc(define.ident_start, this.state.tokenLengthAt(define.ident_start));
                return error.Runtime;
            }

            const t_var = if (scope.getVariable(define.t)) |t_var| t_var else {
                this.state.logErr("type '{s}' not defined", .{define.t});
                this.state.srcLoc(define.type_start, this.state.tokenLengthAt(define.type_start));
                return error.Runtime;
            };

            const t = if (t_var.* == .t) t_var.t else {
                this.state.logErr("expected 'type' got '{t}'", .{t_var.*});
                this.state.srcLoc(define.type_start, this.state.tokenLengthAt(define.type_start));
                return error.Runtime;
            };

            try scope.variables.put(this.state.alloc, define.ident, t.default());
        },
        .assign => |assign| {
            const variable = try scope.getOrCreateVariable(this, assign.ident);
            const value = try this.evalExpression(scope, assign.value);
            if (@as(Type, value) != variable.* and variable.* != .undef) {
                const start = assign.value.value(this.state).start;
                this.state.logErr("expected type of '{t}' got '{t}'", .{ variable.*, value });
                this.state.srcLoc(start, this.state.tokenLengthAt(start));
                return error.Runtime;
            }

            variable.deinit(this.state);
            variable.* = try value.copy(this.state);
        },
        .output => |output| {
            for (output.items) |expression| {
                const value = try this.evalExpression(scope, expression);
                try this.state.out_writer.print("{f}", .{value});
            }
            try this.state.out_writer.print("\n", .{});
            try this.state.out_writer.flush();
        },
        .input => |input| {
            const variable = if (scope.getVariable(input.ident)) |x| x else {
                this.state.logErr("variable '{s}' not defined", .{input.ident});
                return error.Runtime;
            };

            var line_buffer: [256]u8 = undefined;
            var line_writer: std.Io.Writer = .fixed(&line_buffer);

            var len = try this.state.in_reader.streamDelimiterLimit(&line_writer, '\n', .limited(line_buffer.len));
            try this.state.in_reader.discardAll(1);

            if (builtin.os.tag == .windows) {
                if (len > 0 and line_buffer[len - 1] == '\r') len -= 1;
            }

            const line = line_buffer[0..len];
            const value: Value = switch (variable.*) {
                .int => .{ .int = std.fmt.parseInt(State.types.Int, line, 0) catch |err| {
                    this.state.logErr("{t}", .{err});
                    return error.Runtime;
                } },
                .real => .{ .real = std.fmt.parseFloat(State.types.Real, line) catch |err| {
                    this.state.logErr("{t}", .{err});
                    return error.Runtime;
                } },
                .str => .{ .str = line },
                else => {
                    this.state.logErr("cant input to type '{t}'", .{variable.*});
                    return error.Runtime;
                },
            };

            variable.deinit(this.state);
            variable.* = try value.copy(this.state);
        },
        .@"for" => |@"for"| {
            // TODO: allow for non int counters
            var new_scope: Scope = .{
                .parent = scope,
                .variables = .empty,
            };

            try runStatement(this, &new_scope, @"for".assign);
            const variable = new_scope.getVariable(@"for".assign.value(this.state).data.assign.ident) orelse unreachable;
            const limit = try evalExpression(this, &new_scope, @"for".limit);
            const int_limit = (try limit.coerceType(this.state, .int)).int;

            while (true) {
                const as_int = (try variable.coerceType(this.state, .int)).int;
                if (as_int > int_limit) break;

                try runCodeBlock(this, @"for".block, &new_scope);

                variable.* = .{ .int = as_int + 1 };
            }
        },
    }
}

pub fn evalExpression(this: *@This(), scope: *Scope, expression_handle: Parser.Expression.Handle) !Value {
    const expression = expression_handle.value(this.state);

    return switch (expression.data) {
        .int => |int| .{ .int = int },
        .real => |real| .{ .real = real },
        .ident => |ident| if (scope.getVariable(ident)) |val| val.* else {
            this.state.logErr("variable '{s}' not defined", .{ident});
            this.state.srcLoc(expression.start, @intCast(ident.len));
            return error.Runtime;
        },
        .str => |str| {
            const message = try Lexer.getStringAt(this.state, str.start);
            errdefer this.state.alloc.free(message);

            return .{ .str = message };
        },
        .neg => |neg| try (try evalExpression(this, scope, neg)).neg(this.state),
        .bin => |bin| return Value.binOp(
            try evalExpression(this, scope, bin.left),
            try evalExpression(this, scope, bin.right),
            bin.op,
            this.state,
        ),
    };
}

pub fn addRuntimePrimatives(this: *@This(), scope: *Scope) !void {
    try scope.variables.put(this.state.alloc, "INTEGER", .{ .t = .int });
    try scope.variables.put(this.state.alloc, "REAL", .{ .t = .real });
}

pub const Type = enum {
    /// internal usage only
    undef,
    int,
    real,
    str,
    t,

    pub fn default(t: Type) Value {
        return switch (t) {
            .undef => @panic("undef should only be used for internal stuff. a variable should never have type undef when facing the user"),
            .int => .{ .int = 0 },
            .real => .{ .real = 0 },
            .str => .{ .str = &.{} },
            .t => @panic("no default type"),
        };
    }
};

pub const Value = union(Type) {
    undef: void,
    int: State.types.Int,
    real: State.types.Real,
    str: []u8,
    t: Type,

    pub fn deinit(this: @This(), state: *State) void {
        switch (this) {
            .str => |str| state.alloc.free(str),
            else => {},
        }
    }

    pub fn copy(this: @This(), state: *State) !@This() {
        switch (this) {
            .str => |str| return .{ .str = try state.alloc.dupe(u8, str) },
            else => return this,
        }
    }

    pub fn neg(this: @This(), state: *State) !@This() {
        switch (this) {
            .int => |int| return .{ .int = -int },
            .real => |real| return .{ .real = -real },
            else => {
                state.logErr("cannot negate type '{t}'", .{this});
                return error.Runtime;
            },
        }
    }

    pub fn binOp(left: @This(), right: @This(), op: Parser.BinaryOp.Op, state: *State) !@This() {
        switch (op) {
            .add, .sub, .mul => {
                try assertNumeric(left, state);
                try assertNumeric(right, state);

                const new_left = if (right == .real) try left.coerceType(state, .real) else left;
                const new_right = if (left == .real) try right.coerceType(state, .real) else right;

                return switch (op) {
                    .add => if (new_left == .int) .{ .int = new_left.int + new_right.int } else .{ .real = new_left.real + new_right.real },
                    .sub => if (new_left == .int) .{ .int = new_left.int - new_right.int } else .{ .real = new_left.real - new_right.real },
                    .mul => if (new_left == .int) .{ .int = new_left.int * new_right.int } else .{ .real = new_left.real * new_right.real },
                    else => unreachable,
                };
            },
            .div => {
                const new_left = try left.coerceType(state, .real);
                const new_right = try right.coerceType(state, .real);

                return .{ .real = new_left.real / new_right.real };
            },
        }
    }

    pub fn assertNumeric(this: @This(), state: *State) !void {
        switch (this) {
            .int, .real => return,
            else => {
                state.logErr("expected numeric type", .{});
                return error.Runtime;
            },
        }
    }

    pub fn coerceType(this: @This(), state: *State, t: Type) !@This() {
        if (this == t) return this.copy(state);

        switch (t) {
            .int => switch (this) {
                .int => unreachable,
                .real => |real| return .{ .int = @intFromFloat(real) },
                else => {},
            },
            .real => switch (this) {
                .real => unreachable,
                .int => |int| return .{ .real = @floatFromInt(int) },
                else => {},
            },
            else => {},
        }

        state.logErr("cannot coerce type '{t}' to '{t}'", .{ this, t });
        return error.Runtime;
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        switch (this) {
            .int => |int| try writer.print("{}", .{int}),
            .real => |real| try writer.print("{}", .{real}),
            .str => |str| try writer.print("{s}", .{str}),
            else => try writer.print("{s}", .{@tagName(this)}),
        }
    }
};

pub const Scope = struct {
    variables: std.StringHashMapUnmanaged(Value),
    parent: ?*Scope,

    pub fn getOrCreateVariable(this: *@This(), runner: *Runner, name: []const u8) error{OutOfMemory}!*Value {
        if (getVariable(this, name)) |variable| return variable;

        try this.variables.put(runner.state.alloc, name, .undef);
        return this.variables.getPtr(name).?;
    }

    pub fn getVariable(this: *@This(), name: []const u8) ?*Value {
        var scope = this;
        while (true) {
            if (scope.variables.getPtr(name)) |value|
                return value;

            if (scope.parent) |parent| {
                scope = parent;
                continue;
            }

            return null;
        }
    }
};
