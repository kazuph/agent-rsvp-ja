const std = @import("std");

extern fn agent_rsvp_app_main(argc: c_int, argv: [*][*:0]u8) c_int;

pub fn main() u8 {
    return @intCast(agent_rsvp_app_main(@intCast(std.os.argv.len), std.os.argv.ptr));
}
