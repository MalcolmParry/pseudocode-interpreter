const std = @import("std");
const types = @import("types.zig");

pub const Token = struct {
    pub const Data = union(enum) {
        pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

        err: []const u8,
        eof,
        ident: []const u8,
        int: types.Int,
        real: types.Real,
        add,
        sub,
        mul,
        div,
        lparen,
        rparen,
        assign,
        less,
        more,

        pub fn isLiteral(tag: Tag) bool {
            return switch (tag) {
                .int => true,
                .real => true,
                else => false,
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this) {
                .err => |err| try writer.print("err '{s}' ", .{err}),
                .int => |int| try writer.print("{}", .{int}),
                .real => |real| try writer.print("{}f", .{real}),
                .ident => |ident| try writer.print("ident: '{s}'", .{ident}),
                else => try writer.print("{s} ", .{@tagName(this)}),
            }
        }
    };

    start: u32,
    data: Data,
};

src: []const u8,
index: u32,

pub fn init(src: []const u8) @This() {
    return .{
        .src = src,
        .index = 0,
    };
}

pub fn nextToken(this: *@This()) Token {
    while (this.peekChar(0) != null and std.ascii.isWhitespace(this.peekChar(0).?))
        this.index += 1;

    const maybe_c = this.peekChar(0);
    const start = this.index;
    if (maybe_c == null) return .{
        .start = @intCast(this.src.len - 1),
        .data = .eof,
    };

    const c = maybe_c.?;
    if (std.ascii.isDigit(c)) return this.parseNum();
    if (std.ascii.isAlphabetic(c) or c == '_') return this.parseIdentifier();

    const token: Token.Data = switch (c) {
        '+' => .add,
        '-' => .sub,
        '*' => .mul,
        '/' => if (this.peekChar(1) == '/') {
            this.index += 2;

            while (this.peekChar(0) != '\n' and this.peekChar(0) != null) {
                this.index += 1;
            }

            this.index += 1;
            return this.nextToken();
        } else .div,
        '(' => .lparen,
        ')' => .rparen,
        '<' => if (this.peekChar(1) == '-') blk: {
            this.index += 1;
            break :blk .assign;
        } else .less,
        '>' => .more,
        else => .{
            .err = "unrecognised symbol",
        },
    };

    this.index += 1;
    return .{
        .start = start,
        .data = token,
    };
}

pub fn parseNum(this: *@This()) Token {
    const start = this.index;
    var radix: bool = false;

    while (true) {
        const maybe_c = this.peekChar(0);
        const valid = if (maybe_c) |c| std.ascii.isDigit(c) else false;

        if (valid) {
            this.index += 1;
            continue;
        }

        const c = maybe_c.?;
        if (c == '.') {
            if (radix) {
                return .{
                    .start = start,
                    .data = .{
                        .err = "double radix point",
                    },
                };
            }

            radix = true;
            this.index += 1;
            continue;
        }

        const str = this.src[start..this.index];
        return .{
            .start = start,
            .data = if (radix) .{
                .real = std.fmt.parseFloat(types.Real, str) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                },
            } else .{
                .int = std.fmt.parseInt(types.Int, str, 0) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => {
                        return .{
                            .start = start,
                            .data = .{ .err = "int overflow" },
                        };
                    },
                },
            },
        };
    }
}

pub fn parseIdentifier(this: *@This()) Token {
    const start = this.index;

    while (true) {
        const maybe_c = this.peekChar(0);
        const valid = if (maybe_c) |c| std.ascii.isAlphanumeric(c) or c == '_' else false;

        if (valid) {
            this.index += 1;
            continue;
        }

        return .{
            .start = start,
            .data = .{
                .ident = this.src[start..this.index],
            },
        };
    }
}

pub fn peekChar(this: *@This(), offset: usize) ?u8 {
    if (this.index + offset >= this.src.len) return null;
    return this.src[this.index + offset];
}

pub fn peekToken(this: *@This()) Token {
    var copy = this.*;
    return copy.nextToken();
}
