const std = @import("std");
const builtin = @import("builtin");
const State = @import("State.zig");
const Parser = @import("Parser.zig");
const Lexer = @import("Lexer.zig");

const Runner = @This();
const Error = error{ OutOfMemory, Runtime, WriteFailed, ReadFailed, StreamTooLong, EndOfStream, Overflow };

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
            const ident = define.ident_loc.getIdent(this.state);
            const t_name = define.type_loc.getIdent(this.state);

            if (scope.variables.contains(ident)) {
                this.state.logErr("variable '{s}' already defined", .{ident});
                define.ident_loc.printToken(this.state);
                return error.Runtime;
            }

            const t_var = if (scope.getVariable(t_name)) |t_var| t_var else {
                this.state.logErr("type '{s}' not defined", .{t_name});
                define.type_loc.printToken(this.state);
                return error.Runtime;
            };

            const t = if (t_var.* == .t) t_var.t else {
                this.state.logErr("expected 'type' got '{t}'", .{t_var.*});
                define.type_loc.printToken(this.state);
                return error.Runtime;
            };

            try scope.variables.put(this.state.alloc, ident, t.default());
        },
        .assign => |assign| {
            const ident = assign.ident_loc.getIdent(this.state);
            const variable = try scope.getOrCreateVariable(this, ident);
            const value = try this.evalExpression(scope, assign.value);

            if (@as(Type, value) != variable.* and variable.* != .undef) {
                this.state.logErr("expected type of '{t}' got '{t}'", .{ variable.*, value });
                assign.value.value(this.state).src_slice.printWithUnderline(this.state);
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
            const ident = input.ident_loc.getIdent(this.state);
            const variable = if (scope.getVariable(ident)) |x| x else {
                this.state.logErr("variable '{s}' not defined", .{ident});
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
        .for_ => |for_| {
            // TODO: allow for non int counters
            var new_scope: Scope = .{
                .parent = scope,
                .variables = .empty,
            };

            const ident = for_.assign.value(this.state).data.assign.ident_loc.getIdent(this.state);
            try runStatement(this, &new_scope, for_.assign);
            const variable = new_scope.getVariable(ident) orelse unreachable;
            const limit = try evalExpression(this, &new_scope, for_.limit);
            const int_limit = (try limit.coerceType(this.state, .int)).int;

            while (true) {
                const as_int = (try variable.coerceType(this.state, .int)).int;
                if (as_int > int_limit) break;

                try runCodeBlock(this, for_.block, &new_scope);

                variable.* = .{ .int = as_int + 1 };
            }
        },
        .if_ => |if_| {
            const condition_value = try this.evalExpression(scope, if_.condition);
            try condition_value.assertType(this.state, .bool_);

            if (condition_value.bool_)
                try this.runCodeBlock(if_.block, scope);
        },
    }
}

pub fn evalExpression(this: *@This(), scope: *Scope, expression_handle: Parser.Expression.Handle) !Value {
    const expression = expression_handle.value(this.state);
    const loc = expression.src_slice.loc();

    return switch (expression.data) {
        .int => .{ .int = try loc.getInt(this.state) },
        .real => .{ .real = try loc.getReal(this.state) },
        .ident => {
            const ident = loc.getIdent(this.state);

            if (scope.getVariable(ident)) |val| {
                return val.*;
            } else {
                this.state.logErr("variable '{s}' not defined", .{ident});
                expression.src_slice.printWithUnderline(this.state);
                return error.Runtime;
            }
        },
        .str => {
            const message = try loc.getString(this.state);
            errdefer this.state.alloc.free(message);

            return .{ .str = message };
        },
        .neg => |neg| try (try evalExpression(this, scope, neg)).neg(this.state),
        .bin => |bin| {
            var left = try evalExpression(this, scope, bin.left);
            var right = try evalExpression(this, scope, bin.right);

            switch (bin.op) {
                .add, .sub, .mul => {
                    if (right == .real) left = try left.coerceType(this.state, .real);
                    if (left == .real) right = try right.coerceType(this.state, .real);

                    return switch (right) {
                        .int => .{ .int = Value.arithmeticBinOp(State.types.Int, left.int, right.int, bin.op) },
                        .real => .{ .real = Value.arithmeticBinOp(State.types.Real, left.real, right.real, bin.op) },
                        else => {
                            this.state.logErr("wrong type {t}", .{left});
                            return error.Runtime;
                        },
                    };
                },
                .div => {
                    left = try left.coerceType(this.state, .real);
                    right = try right.coerceType(this.state, .real);

                    return .{ .real = left.real / right.real };
                },
                .eq, .not_eq => {
                    if (right == .real) left = try left.coerceType(this.state, .real);
                    if (left == .real) right = try right.coerceType(this.state, .real);
                    if (@as(Type, right) != left) {
                        this.state.logErr("mismatch in type", .{});
                        return error.Runtime;
                    }

                    var result = switch (right) {
                        .int => left.int == right.int,
                        .real => left.real == right.real,
                        .bool_ => left.bool_ == right.bool_,
                        .str => std.mem.eql(u8, left.str, right.str),
                        else => {
                            this.state.logErr("wrong type {t}", .{left});
                            return error.Runtime;
                        },
                    };

                    if (bin.op == .not_eq) result = !result;
                    return .{ .bool_ = result };
                },
                .more, .less, .more_eq, .less_eq => {
                    if (right == .real) left = try left.coerceType(this.state, .real);
                    if (left == .real) right = try right.coerceType(this.state, .real);

                    return switch (right) {
                        .int => .{ .bool_ = Value.boolBinOp(State.types.Int, left.int, right.int, bin.op) },
                        .real => .{ .bool_ = Value.boolBinOp(State.types.Real, left.real, right.real, bin.op) },
                        else => {
                            this.state.logErr("wrong type {t}", .{left});
                            return error.Runtime;
                        },
                    };
                },
                .and_, .or_ => {
                    try left.assertType(this.state, .bool_);
                    try right.assertType(this.state, .bool_);

                    return switch (bin.op) {
                        .and_ => .{ .bool_ = left.bool_ and right.bool_ },
                        .or_ => .{ .bool_ = left.bool_ or right.bool_ },
                        else => unreachable,
                    };
                },
            }
        },
    };
}

pub fn addRuntimePrimatives(this: *@This(), scope: *Scope) !void {
    try scope.variables.put(this.state.alloc, "INTEGER", .{ .t = .int });
    try scope.variables.put(this.state.alloc, "REAL", .{ .t = .real });
    try scope.variables.put(this.state.alloc, "BOOLEAN", .{ .t = .bool_ });

    try scope.variables.put(this.state.alloc, "TRUE", .{ .bool_ = true });
    try scope.variables.put(this.state.alloc, "FALSE", .{ .bool_ = false });
}

pub const Type = enum {
    /// internal usage only
    undef,
    int,
    real,
    str,
    bool_,
    t,

    pub fn default(t: Type) Value {
        return switch (t) {
            .undef => @panic("undef should only be used for internal stuff. a variable should never have type undef when facing the user"),
            .int => .{ .int = 0 },
            .real => .{ .real = 0 },
            .str => .{ .str = &.{} },
            .bool_ => .{ .bool_ = false },
            .t => @panic("no default type"),
        };
    }
};

pub const Value = union(Type) {
    undef: void,
    int: State.types.Int,
    real: State.types.Real,
    str: []u8,
    bool_: bool,
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

    pub fn arithmeticBinOp(T: type, left: T, right: T, op: Parser.BinaryOp.Op) T {
        return switch (op) {
            .add => left + right,
            .sub => left - right,
            .mul => left * right,
            .div => if (@typeInfo(T) == .int) @divTrunc(left, right) else left / right,
            else => @panic("wrong type"),
        };
    }

    pub fn boolBinOp(T: type, left: T, right: T, op: Parser.BinaryOp.Op) bool {
        return switch (op) {
            .eq => left == right,
            .not_eq => left != right,
            .more => left > right,
            .less => left < right,
            .more_eq => left >= right,
            .less_eq => left <= right,
            else => @panic("wrong type"),
        };
    }

    pub fn assertType(this: @This(), state: *State, expected: Type) !void {
        if (this != expected) {
            state.logErr("expected '{t}' got '{t}'", .{ expected, this });
            return error.Runtime;
        }
    }

    pub fn isNumeric(this: Type) bool {
        switch (this) {
            .int, .real => true,
            else => false,
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
            .bool_ => |bool_| try writer.print("{}", .{bool_}),
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
