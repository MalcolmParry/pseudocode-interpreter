const std = @import("std");

alloc: std.mem.Allocator,
src: []const u8,
err_writer: *std.Io.Writer,

pub fn err(this: *@This(), comptime fmt: []const u8, args: anytype) void {
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .red) catch @panic("color setting failed");
    this.err_writer.print("error: " ++ fmt ++ "\n", args) catch @panic("printing failed");
    std.Io.tty.Config.setColor(.escape_codes, this.err_writer, .reset) catch @panic("color setting failed");
    this.err_writer.flush() catch @panic("cant flush");
}

pub fn srcLoc(this: *@This(), start: u32, len: u32) void {
    std.debug.assert(start < this.src.len);

    const tty: std.Io.tty.Config = .escape_codes;

    var line_start: u32 = 0;
    for (this.src[0..start], 0..) |c, i| {
        if (c == '\n') line_start = @intCast(i + 1);
    }

    var line_len: u32 = 0;
    for (this.src[line_start..]) |c| {
        if (c == '\n') break;
        line_len += 1;
    }

    this.err_writer.print("{s}\n", .{this.src[line_start .. line_start + line_len]}) catch @panic("failed printing");
    for (0..start - line_start) |_| this.err_writer.print(" ", .{}) catch @panic("failed printing");

    tty.setColor(this.err_writer, .green) catch @panic("failed to set color");
    this.err_writer.print("^", .{}) catch @panic("failed printing");
    for (0..len - 1) |_| this.err_writer.print("~", .{}) catch @panic("failed printing");
    this.err_writer.print("\n", .{}) catch @panic("failed printing");
    tty.setColor(this.err_writer, .reset) catch @panic("failed to set color");
    this.err_writer.flush() catch @panic("failed flushing");
}
