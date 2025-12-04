const std = @import("std");
const State = @import("State.zig");

state: *State,
index: u32 = 0,

pub fn nextToken(this: *@This()) !Token {
    while (true) {
        const token = try this.nextTokenInternal();
        if (token.t != .whitespace) return token;
    }
}

pub fn nextTokenInternal(this: *@This()) error{Lexer}!Token {
    const start = this.index;
    const c = if (this.peekChar(0)) |c| c else return .{
        .start = @intCast(this.state.src.len - 1),
        .t = .eof,
    };

    if (std.ascii.isWhitespace(c)) {
        while (if (this.peekChar(0)) |c2| std.ascii.isWhitespace(c2) else false) {
            this.index += 1;
        }

        return .{ .start = start, .t = .whitespace };
    }

    if (std.ascii.isDigit(c)) return try this.parseNum();
    if (std.ascii.isAlphabetic(c) or c == '_') return this.parseIdentifier();

    const t: Token.Type = switch (c) {
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
        ',' => .comma,
        '\"' => return this.parseString(),
        else => {
            this.state.logErr("unexpected character '{c}'", .{c});
            this.state.srcLoc(start, 1);
            return error.Lexer;
        },
    };

    this.index += 1;
    return .{
        .start = start,
        .t = t,
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

        return .{
            .start = start,
            .t = if (radix_point) .real else .int,
        };
    }
}

pub fn parseString(this: *@This()) !Token {
    const start = this.index;
    var len: u32 = 0;
    this.index += 1;

    while (true) {
        const valid = if (this.peekChar(0)) |c| blk: {
            if (c == '\n') break :blk false;
            break :blk true;
        } else false;

        if (!valid) {
            this.state.logErr("expected closing '\"'", .{});
            this.state.srcLoc(this.index - 1, 1);
            return error.Lexer;
        }

        const c = this.peekChar(0).?;
        if (c == '"') break;

        len += 1;
        this.index += 1;
    }

    this.index += 1;
    return .{
        .start = start,
        .t = .str,
    };
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
        const t: Token.Type = blk: {
            if (std.mem.eql(u8, str, "DECLARE")) break :blk .declare;
            if (std.mem.eql(u8, str, "OUTPUT")) break :blk .output;
            if (std.mem.eql(u8, str, "INPUT")) break :blk .input;
            if (std.mem.eql(u8, str, "FOR")) break :blk .for_loop;
            if (std.mem.eql(u8, str, "TO")) break :blk .to;
            if (std.mem.eql(u8, str, "NEXT")) break :blk .next;

            break :blk .ident;
        };

        return .{
            .start = start,
            .t = t,
        };
    }
}

/// assumes no errors
pub fn getIntAt(state: *State, start: u32) !State.types.Int {
    const len = state.tokenLengthAt(start);

    return std.fmt.parseInt(State.types.Int, state.src[start .. start + len], 0) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
        error.Overflow => {
            state.logErr("integer overflow", .{});
            state.srcLoc(start, len);
            return error.Lexer;
        },
    };
}

/// assumes no errors
pub fn getRealAt(state: *State, start: u32) !State.types.Real {
    const len = state.tokenLengthAt(start);

    return std.fmt.parseFloat(State.types.Real, state.src[start .. start + len]) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
    };
}

/// assumes no errors as parseString should have already been called
pub fn getStringAt(state: *State, start: u32) error{OutOfMemory}![]u8 {
    var this: @This() = .{
        .state = state,
        .index = start,
    };

    var len: u32 = 0;
    this.index += 1;

    while (true) {
        const c = this.peekChar(0).?;
        if (c == '"') break;

        len += 1;
        this.index += 1;
    }

    const str = try this.state.alloc.alloc(u8, len);
    errdefer this.state.alloc.free(str);

    const full_len = this.index - start;
    for (0..full_len - 1, this.state.src[start + 1 .. start + full_len]) |i, c| {
        str[i] = c;
    }

    this.index += 1;
    return str;
}

/// assumes no errors
pub fn getIdentAt(state: *State, start: u32) []const u8 {
    const len = state.tokenLengthAt(start);

    return state.src[start .. start + len];
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
    t: Type,

    pub const Type = enum {
        eof,
        whitespace,
        ident,
        // literal
        int,
        real,
        str,
        // bin op
        add,
        sub,
        mul,
        div,
        less,
        more,
        // symbol
        assign,
        comma,
        colon,
        lparen,
        rparen,
        // keyword
        declare,
        output,
        input,
        for_loop,
        to,
        next,

        pub fn isLiteral(t: Type) bool {
            return switch (t) {
                .int => true,
                .real => true,
                else => false,
            };
        }
    };

    pub const Formatter = struct {
        state: *State,
        this: Token,

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this.this.t) {
                .int => try writer.print("{}", .{getIntAt(this.state, this.this.start) catch return error.WriteFailed}),
                .real => try writer.print("{}f", .{getRealAt(this.state, this.this.start) catch return error.WriteFailed}),
                .ident => try writer.print("@'{s}'", .{getIdentAt(this.state, this.this.start)}),
                else => try writer.print("{s}", .{@tagName(this.this.t)}),
            }
        }
    };
};
