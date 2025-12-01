const std = @import("std");
const types = @import("types.zig");
const State = @import("State.zig");

state: *State,
index: u32 = 0,

pub fn nextToken(this: *@This()) !Token {
    while (true) {
        const token = try this.nextTokenInternal();
        if (token.data != .whitespace) return token;
    }
}

pub fn nextTokenInternal(this: *@This()) error{Lexer}!Token {
    const start = this.index;
    const c = if (this.peekChar(0)) |c| c else return .{
        .start = @intCast(this.state.src.len - 1),
        .data = .eof,
    };

    if (std.ascii.isWhitespace(c)) {
        while (if (this.peekChar(0)) |c2| std.ascii.isWhitespace(c2) else false) {
            this.index += 1;
        }

        return .{ .start = start, .data = .whitespace };
    }

    if (std.ascii.isDigit(c)) return try this.parseNum();
    if (std.ascii.isAlphabetic(c) or c == '_') return this.parseIdentifier();

    const token: Token.Data = switch (c) {
        ':' => .colon,
        '+' => .add,
        '-' => .sub,
        '*' => .mul,
        '/' => if (this.peekChar(1) == '/') blk: {
            this.index += 2;

            while (this.peekChar(0) != '\n' and this.peekChar(0) != null) {
                this.index += 1;
            }

            break :blk .whitespace;
        } else .div,
        '(' => .lparen,
        ')' => .rparen,
        '<' => if (this.peekChar(1) == '-') blk: {
            this.index += 1;
            break :blk .assign;
        } else .less,
        '>' => .more,
        else => {
            this.state.logErr("unexpected character '{c}'", .{c});
            this.state.srcLoc(start, 1);
            return error.Lexer;
        },
    };

    this.index += 1;
    return .{
        .start = start,
        .data = token,
    };
}

pub fn parseNum(this: *@This()) error{Lexer}!Token {
    const start = this.index;
    var radix_point: bool = false;

    while (true) {
        const maybe_c = this.peekChar(0);
        const valid = if (maybe_c) |c| std.ascii.isDigit(c) or c == '.' else false;

        if (valid) {
            const c = maybe_c.?;
            if (c == '.') {
                if (radix_point) {
                    this.state.logErr("double radix point", .{});
                    this.state.srcLoc(this.index, 1);
                    return error.Lexer;
                }

                radix_point = true;
            }

            this.index += 1;
            continue;
        }

        const str = this.state.src[start..this.index];
        return .{
            .start = start,
            .data = if (radix_point) .{
                .real = std.fmt.parseFloat(types.Real, str) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                },
            } else .{
                .int = std.fmt.parseInt(types.Int, str, 0) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => {
                        this.state.logErr("integer overflow", .{});
                        this.state.srcLoc(start, this.index - start);
                        return error.Lexer;
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

        const str = this.state.src[start..this.index];
        const data: Token.Data = blk: {
            if (std.mem.eql(u8, str, "DEFINE")) break :blk .define;
            if (std.mem.eql(u8, str, "OUTPUT")) break :blk .output;

            break :blk .{ .ident = str };
        };

        return .{
            .start = start,
            .data = data,
        };
    }
}

pub fn peekChar(this: *@This(), offset: usize) ?u8 {
    if (this.index + offset >= this.state.src.len) return null;
    return this.state.src[this.index + offset];
}

pub fn peekToken(this: *@This()) error{Lexer}!Token {
    var copy = this.*;
    return copy.nextToken();
}

pub const Token = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

        eof,
        whitespace,
        ident: []const u8,
        // literal
        int: types.Int,
        real: types.Real,
        // bin op
        add,
        sub,
        mul,
        div,
        less,
        more,
        // symbol
        assign,
        colon,
        lparen,
        rparen,
        // keyword
        define,
        output,

        pub fn isLiteral(tag: Tag) bool {
            return switch (tag) {
                .int => true,
                .real => true,
                else => false,
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this) {
                .int => |int| try writer.print("{}", .{int}),
                .real => |real| try writer.print("{}f", .{real}),
                .ident => |ident| try writer.print("@'{s}'", .{ident}),
                else => try writer.print("{s} ", .{@tagName(this)}),
            }
        }
    };
};
