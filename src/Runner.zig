const std = @import("std");
const State = @import("State.zig");
const Parser = @import("Parser.zig");

const Runner = @This();

state: *State,
parser: *Parser,

pub fn runCodeBlock(this: *@This(), block: Parser.CodeBlock.Handle, parent_scope: ?*Scope) error{ OutOfMemory, Runtime }!void {
    var scope: Scope = .{
        .variables = .empty,
        .parent = parent_scope,
    };

    for (block.value(this.state).statements) |statement_handle| {
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
                const value = try this.evalExpression(&scope, assign.value);
                if (@as(Type, value) != variable.*) {
                    const start = assign.value.value(this.state).start;
                    this.state.logErr("expected type of '{t}' got '{t}'", .{ variable.*, value });
                    this.state.srcLoc(start, this.state.tokenLengthAt(start));
                    return error.Runtime;
                }

                variable.* = value;
            },
            .output => |output| {
                const value = try this.evalExpression(&scope, output);
                std.log.scoped(.pseudo).info("{f}", .{value});
            },
        }
    }
}

pub fn evalExpression(this: *@This(), scope: *Scope, expression_handle: Parser.Expression.Handle) !Value {
    const expression = expression_handle.value(this.state);

    return switch (expression.data) {
        .lit => |lit| switch (lit) {
            .int => |int| .{ .int = int },
            .real => |real| .{ .real = real },
            .ident => |ident| if (scope.getVariable(ident)) |val| val.* else {
                this.state.logErr("variable '{s}' not defined", .{ident});
                this.state.srcLoc(expression.start, @intCast(ident.len));
                return error.Runtime;
            },
            else => unreachable,
        },
        else => unreachable, // temporary
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
    t,

    pub fn default(t: Type) Value {
        return switch (t) {
            .undef => @panic("undef should only be used for internal stuff. a variable should never have type undef when facing the user"),
            .int => .{ .int = 0 },
            .real => .{ .real = 0 },
            .t => @panic("no default type"),
        };
    }
};

pub const Value = union(Type) {
    undef: void,
    int: State.types.Int,
    real: State.types.Real,
    t: Type,

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        switch (this) {
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
