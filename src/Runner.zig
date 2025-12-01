const std = @import("std");
const Parser = @import("Parser.zig");
const types = @import("types.zig");

const Runner = @This();

parser: *Parser,
alloc: std.mem.Allocator,
root: Parser.CodeBlock.Handle,

pub fn runCodeBlock(this: *@This(), block: Parser.CodeBlock.Handle, parent_scope: ?*Scope) error{OutOfMemory}!?Error {
    var scope: Scope = .{
        .variables = .empty,
        .parent = parent_scope,
    };

    for (block.value(this.parser).statements) |statement| {
        switch (statement.value(this.parser).data) {
            .define => |define| {
                if (scope.variables.contains(define.ident)) return .{
                    .start = statement.value(this.parser).start,
                    .message = "variable already defined",
                };

                const t_var = if (scope.getVariable(define.t)) |t_var| t_var else return .{
                    .start = statement.value(this.parser).start,
                    .message = "type not defined",
                };

                const t = if (t_var.* == .t) t_var.t else return .{
                    .start = statement.value(this.parser).start,
                    .message = "expected type",
                };

                try scope.variables.put(this.alloc, define.ident, t.default());
            },
            .assign => |assign| {
                const variable = try scope.getOrCreateVariable(this, assign.ident);
                const value = try this.evalExpression(&scope, assign.value);
                if (value == .err) return value.err;
                if (@as(Type, value.value) != variable.*) return .{
                    .start = 0, // fix
                    .message = "wrong type",
                };

                variable.* = value.value;
            },
            .output => |output| {
                const value = try this.evalExpression(&scope, output);
                if (value == .err) return value.err;
                std.log.scoped(.pseudo).info("{f}", .{value.value});
            },
            .err => unreachable,
        }
    }

    return null;
}

pub fn evalExpression(this: *@This(), scope: *Scope, expression_handle: Parser.Expression.Handle) !ValueOrError {
    const expression = expression_handle.value(this.parser);

    const value: Value = switch (expression.data) {
        .lit => |lit| switch (lit) {
            .int => |int| .{ .int = int },
            .real => |real| .{ .real = real },
            .ident => |ident| if (scope.getVariable(ident)) |val| val.* else return .{ .err = .{ .start = expression.start, .message = "variable not defined" } },
            else => unreachable,
        },
        .err => unreachable,
        else => unreachable, // temporary
    };

    return .{ .value = value };
}

pub fn addRuntimePrimatives(this: *@This(), scope: *Scope) !void {
    try scope.variables.put(this.alloc, "INTEGER", .{ .t = .int });
    try scope.variables.put(this.alloc, "REAL", .{ .t = .real });
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
            .t => @panic("thign"), // get better messages
        };
    }
};

pub const Value = union(Type) {
    undef: void,
    int: types.Int,
    real: types.Real,
    t: Type,

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        switch (this) {
            else => try writer.print("{s}", .{@tagName(this)}),
        }
    }
};

pub const ValueOrError = union(enum) {
    value: Value,
    err: Error,
};

pub const Scope = struct {
    variables: std.StringHashMapUnmanaged(Value),
    parent: ?*Scope,

    pub fn getOrCreateVariable(this: *@This(), runner: *Runner, name: []const u8) error{OutOfMemory}!*Value {
        if (getVariable(this, name)) |variable| return variable;

        try this.variables.put(runner.alloc, name, .undef);
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

pub const Error = struct {
    start: u32,
    message: []const u8,
};
