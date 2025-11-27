const std = @import("std");
const SouceLocation = @import("SourceLocation.zig");
const types = @import("types.zig");

pub const Token = struct {
    const Data = union(enum) {
        err: []const u8,
        eof,
        int: types.Int,
        float,
        add,
        sub,
        mul,
        div,
        whitespace,
    };

    loc: SouceLocation,
    data: Data,

    pub fn format(this: @This(), writer: *std.Io.Writer) !void {
        switch (this.data) {
            .err => |err| try writer.print("err '{s}' ", .{err}),
            .int => |int| try writer.print("int {} ", .{int}),
            else => try writer.print("{s} ", .{@tagName(this.data)}),
        }
    }
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
    if (this.index >= this.src.len) return .{
        .loc = .{
            .line = this.line,
            .col = this.col,
            .len = 1,
        },
        .data = .eof,
    };

    const c = this.src[this.index];
    if (std.ascii.isDigit(c)) return this.parseNum();
    if (std.ascii.isWhitespace(c)) {
        const start_index = this.index;
        const start_line = this.line;
        const start_col = this.col;

        while (std.ascii.isWhitespace(this.src[this.index])) {
            if (this.src[this.index] == '\n') {
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
        if (this.index >= this.src.len or !std.ascii.isDigit(this.src[this.index])) {
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
