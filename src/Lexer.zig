const std = @import("std");
const State = @import("State.zig");

state: *State,
loc: State.SourceLocation = .{ .index = 0 },

pub fn nextToken(this: *@This()) !Token {
    while (true) {
        const token = try this.nextTokenInternal();
        if (token.t != .whitespace) return token;
    }
}

pub fn nextTokenInternal(this: *@This()) error{Lexer}!Token {
    const start = this.loc;
    const c = if (this.peekChar(0)) |c| c else return .{
        .start = .{ .index = @intCast(this.state.src.len - 1) },
        .t = .eof,
    };

    if (std.ascii.isWhitespace(c)) {
        while (if (this.peekChar(0)) |c2| std.ascii.isWhitespace(c2) else false) {
            this.loc.index += 1;
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
            this.loc.index += 2;

            while (this.peekChar(0) != '\n' and this.peekChar(0) != null) {
                this.loc.index += 1;
            }

            break :blk .whitespace;
        } else .div,
        '(' => .lparen,
        ')' => .rparen,
        '<' => switch (this.peekChar(1) orelse 0) {
            '-' => blk: {
                this.loc.index += 1;
                break :blk .assign;
            },
            '>' => blk: {
                this.loc.index += 1;
                break :blk .not_eq;
            },
            '=' => blk: {
                this.loc.index += 1;
                break :blk .less_eq;
            },
            else => .less,
        },
        '>' => switch (this.peekChar(1) orelse 0) {
            '=' => blk: {
                this.loc.index += 1;
                break :blk .more_eq;
            },
            else => .more,
        },
        ',' => .comma,
        '\"' => return this.parseString(),
        '=' => .eq,
        else => {
            this.state.logErr("unexpected character '{c}'", .{c});
            start.print(this.state);
            return error.Lexer;
        },
    };

    this.loc.index += 1;
    return .{
        .start = start,
        .t = t,
    };
}

pub fn parseNum(this: *@This()) error{Lexer}!Token {
    const start = this.loc;
    var radix_point: bool = false;

    while (true) {
        const maybe_c = this.peekChar(0);
        const valid = if (maybe_c) |c| std.ascii.isDigit(c) or c == '.' else false;

        if (valid) {
            const c = maybe_c.?;
            if (c == '.') {
                if (radix_point) {
                    this.state.logErr("double radix point", .{});
                    this.loc.print(this.state);
                    return error.Lexer;
                }

                radix_point = true;
            }

            this.loc.index += 1;
            continue;
        }

        return .{
            .start = start,
            .t = if (radix_point) .real else .int,
        };
    }
}

pub fn parseString(this: *@This()) !Token {
    const start = this.loc;
    var len: u32 = 0;
    this.loc.index += 1;

    while (true) {
        const valid = if (this.peekChar(0)) |c| blk: {
            if (c == '\n') break :blk false;
            break :blk true;
        } else false;

        if (!valid) {
            this.state.logErr("expected closing '\"'", .{});
            this.loc.index -= 1;
            this.loc.print(this.state);
            return error.Lexer;
        }

        const c = this.peekChar(0).?;
        if (c == '"') break;

        len += 1;
        this.loc.index += 1;
    }

    this.loc.index += 1;
    return .{
        .start = start,
        .t = .str,
    };
}

pub fn parseIdentifier(this: *@This()) Token {
    const start = this.loc;

    while (true) {
        const maybe_c = this.peekChar(0);
        const valid = if (maybe_c) |c| std.ascii.isAlphanumeric(c) or c == '_' else false;

        if (valid) {
            this.loc.index += 1;
            continue;
        }

        const str = this.state.src[start.index..this.loc.index];
        const t: Token.Type = blk: {
            if (std.mem.eql(u8, str, "DECLARE")) break :blk .declare;
            if (std.mem.eql(u8, str, "OUTPUT")) break :blk .output;
            if (std.mem.eql(u8, str, "INPUT")) break :blk .input;
            if (std.mem.eql(u8, str, "FOR")) break :blk .for_;
            if (std.mem.eql(u8, str, "TO")) break :blk .to;
            if (std.mem.eql(u8, str, "NEXT")) break :blk .next;
            if (std.mem.eql(u8, str, "AND")) break :blk .and_;
            if (std.mem.eql(u8, str, "OR")) break :blk .or_;
            if (std.mem.eql(u8, str, "NOT")) break :blk .not_;
            if (std.mem.eql(u8, str, "IF")) break :blk .if_;
            if (std.mem.eql(u8, str, "THEN")) break :blk .then;
            if (std.mem.eql(u8, str, "ENDIF")) break :blk .endif;
            if (std.mem.eql(u8, str, "ELSE")) break :blk .else_;
            if (std.mem.eql(u8, str, "REPEAT")) break :blk .repeat;
            if (std.mem.eql(u8, str, "UNTIL")) break :blk .until;

            break :blk .ident;
        };

        return .{
            .start = start,
            .t = t,
        };
    }
}

/// assumes no errors
pub fn getIntAt(loc: State.SourceLocation, state: *State) !State.types.Int {
    const len = loc.tokenLength(state);

    return std.fmt.parseInt(State.types.Int, state.src[loc.index .. loc.index + len], 0) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
        error.Overflow => {
            state.logErr("integer overflow", .{});
            loc.printToken(state);
            return error.Overflow;
        },
    };
}

/// assumes no errors
pub fn getRealAt(loc: State.SourceLocation, state: *State) !State.types.Real {
    const len = loc.tokenLength(state);

    return std.fmt.parseFloat(State.types.Real, state.src[loc.index .. loc.index + len]) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
    };
}

/// assumes no errors as parseString should have already been called
pub fn getStringAt(loc: State.SourceLocation, state: *State) error{OutOfMemory}![]u8 {
    var this: @This() = .{
        .state = state,
        .loc = loc,
    };

    var len: u32 = 0;
    this.loc.index += 1;

    while (true) {
        const c = this.peekChar(0).?;
        if (c == '"') break;

        len += 1;
        this.loc.index += 1;
    }

    const str = try this.state.alloc.alloc(u8, len);
    errdefer this.state.alloc.free(str);

    const full_len = this.loc.index - loc.index;
    for (0..full_len - 1, this.state.src[loc.index + 1 .. loc.index + full_len]) |i, c| {
        str[i] = c;
    }

    this.loc.index += 1;
    return str;
}

/// assumes no errors
pub fn getIdentAt(loc: State.SourceLocation, state: *State) []const u8 {
    const len = loc.tokenLength(state);

    return state.src[loc.index .. loc.index + len];
}

pub fn peekChar(this: *@This(), offset: usize) ?u8 {
    if (this.loc.index + offset >= this.state.src.len) return null;
    return this.state.src[this.loc.index + offset];
}

pub fn peekToken(this: *@This()) error{Lexer}!Token {
    var copy = this.*;
    return copy.nextToken();
}

pub const Token = struct {
    start: State.SourceLocation,
    t: Type,

    pub const Type = enum {
        eof,
        whitespace,
        ident,
        // literal
        int,
        real,
        str,
        // arithmetic bin op
        add,
        sub,
        mul,
        div,
        // relational bin op
        eq,
        not_eq,
        less,
        more,
        less_eq,
        more_eq,
        // logical bin op
        and_,
        or_,
        not_,
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
        for_,
        to,
        next,
        if_,
        then,
        endif,
        else_,
        repeat,
        until,

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
                .int => try writer.print("{}", .{this.this.start.getInt(this.state) catch return error.WriteFailed}),
                .real => try writer.print("{}f", .{this.this.start.getReal(this.state) catch return error.WriteFailed}),
                .ident => try writer.print("@'{s}'", .{this.this.start.getIdent(this.state)}),
                .str => {
                    const str = this.this.start.getString(this.state) catch return error.WriteFailed;
                    defer this.state.alloc.free(str);
                    try writer.print("'{s}'", .{str});
                },
                else => try writer.print("{s}", .{@tagName(this.this.t)}),
            }
        }
    };
};
