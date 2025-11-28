const std = @import("std");
const SouceLocation = @import("SourceLocation.zig");
const types = @import("types.zig");

pub const Token = struct {
    pub const Data = union(enum) {
        pub const Tag = @typeInfo(@This()).@"union".tag_type.?;

        err: []const u8,
        eof,
        int: types.Int,
        float,
        add,
        sub,
        mul,
        div,
        lparen,
        rparen,
        whitespace,

        pub fn isLiteral(tag: Tag) bool {
            return switch (tag) {
                .int => true,
                .float => true,
                else => false,
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this) {
                .err => |err| try writer.print("err '{s}' ", .{err}),
                .int => |int| try writer.print("{}i", .{int}),
                else => try writer.print("{s} ", .{@tagName(this)}),
            }
        }
    };

    loc: SouceLocation,
    data: Data,
};

src: []const u8,
index: usize,
line: u32,
col: u32,

pub fn init(src: []const u8) @This() {
    return .{
        .src = src,
        .index = 0,
        .line = 0,
        .col = 0,
    };
}

pub fn deinit(this: *@This()) void {
    _ = this;
}

pub fn nextToken(this: *@This()) Token {
    const maybe_c = this.peekChar(0);

    if (maybe_c == null) return .{
        .loc = .{
            .line = this.line,
            .col = this.col,
            .len = 1,
        },
        .data = .eof,
    };

    const c = maybe_c.?;
    if (std.ascii.isDigit(c)) return this.parseNum();
    if (std.ascii.isWhitespace(c)) {
        const start_index = this.index;
        const start_line = this.line;
        const start_col = this.col;

        while (this.peekChar(0) != null and std.ascii.isWhitespace(this.peekChar(0).?)) {
            if (this.peekChar(0).? == '\n') {
                this.index += 1;
                this.line += 1;
                this.col = 0;
            } else {
                this.advance();
            }
        }

        return .{
            .loc = .{
                .line = start_line,
                .col = start_col,
                .len = @intCast(this.index - start_index),
            },
            .data = .whitespace,
        };
    }

    const single_loc: SouceLocation = .{
        .line = this.line,
        .col = this.col,
        .len = 1,
    };

    const token: Token = switch (c) {
        '+' => .{
            .loc = single_loc,
            .data = .add,
        },
        '-' => .{
            .loc = single_loc,
            .data = .sub,
        },
        '*' => .{
            .loc = single_loc,
            .data = .mul,
        },
        '/' => .{
            .loc = single_loc,
            .data = .div,
        },
        '(' => .{
            .loc = single_loc,
            .data = .lparen,
        },
        ')' => .{
            .loc = single_loc,
            .data = .rparen,
        },
        else => .{
            .loc = single_loc,
            .data = .{
                .err = "unrecognised symbol",
            },
        },
    };

    this.advance();
    return token;
}

// TODO: allow for flaots too
pub fn parseNum(this: *@This()) Token {
    const start_index = this.index;
    const start_line = this.line;
    const start_col = this.col;

    while (true) {
        const maybe_c = this.peekChar(0);

        if (maybe_c == null or !std.ascii.isDigit(maybe_c.?)) {
            const len: u32 = @intCast(this.index - start_index);
            const loc: SouceLocation = .{
                .line = start_line,
                .col = start_col,
                .len = len,
            };
            const data: Token.Data = .{
                .int = std.fmt.parseInt(types.Int, this.src[start_index .. start_index + len], 0) catch |err| {
                    const message_nt: [*:0]const u8 = @ptrCast(@errorName(err));
                    const message = message_nt[0..std.mem.len(message_nt)];

                    return .{
                        .loc = loc,
                        .data = .{ .err = message },
                    };
                },
            };

            return .{
                .loc = loc,
                .data = data,
            };
        }

        this.advance();
    }
}

pub fn advance(this: *@This()) void {
    this.index += 1;
    this.col += 1;
}

pub fn peekChar(this: *@This(), offset: usize) ?u8 {
    if (this.index + offset >= this.src.len) return null;
    return this.src[this.index];
}

pub fn nextTokenNoWS(this: *@This()) Token {
    while (true) {
        const token = this.nextToken();
        if (token.data != .whitespace) return token;
    }
}

pub fn peekTokenNoWS(this: *@This()) Token {
    var copy = this.*;
    return copy.nextTokenNoWS();
}
