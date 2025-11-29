const std = @import("std");
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
        assign,
        less,
        more,

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
                .int => |int| try writer.print("{}", .{int}),
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

pub fn deinit(this: *@This()) void {
    _ = this;
}

pub fn nextToken(this: *@This()) Token {
    while (this.peekChar(0) != null and std.ascii.isWhitespace(this.peekChar(0).?))
        this.index += 1;

    const maybe_c = this.peekChar(0);
    const start = this.index;
    if (maybe_c == null) return .{
        .start = this.index,
        .data = .eof,
    };

    const c = maybe_c.?;
    if (std.ascii.isDigit(c)) return this.parseNum();

    const token: Token.Data = switch (c) {
        '+' => .add,
        '-' => .sub,
        '*' => .mul,
        '/' => .div,
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

// TODO: allow for flaots too
pub fn parseNum(this: *@This()) Token {
    const start = this.index;

    while (true) {
        const maybe_c = this.peekChar(0);

        if (maybe_c == null or !std.ascii.isDigit(maybe_c.?)) {
            const len: u32 = @intCast(this.index - start);

            return .{
                .start = start,
                .data = .{
                    .int = std.fmt.parseInt(types.Int, this.src[start .. start + len], 0) catch |err| {
                        const message_nt: [*:0]const u8 = @errorName(err);
                        const message = message_nt[0..std.mem.len(message_nt)];

                        return .{
                            .start = start,
                            .data = .{ .err = message },
                        };
                    },
                },
            };
        }

        this.index += 1;
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
