const builtin = @import("builtin");

pub const Config = .{
    .version = "unreleased",
    .debug = builtin.mode == .Debug and false,
    .debug_stack = builtin.mode == .Debug and false,
    .debug_gc = builtin.mode == .Debug and true,
    .debug_gc_light = false,
    .debug_turn_off_gc = builtin.mode == .Debug and false,
    .debug_current_instruction = builtin.mode == .Debug and true,
    .debug_perf = true,
    .debug_stop_on_report = builtin.mode == .Debug and false,
    .debug_placeholders = builtin.mode == .Debug and false,
    .gc = .{
        // In Kb
        .initial_gc = if (builtin.mode == .Debug) 1 else 8,
        .next_gc_ratio = 2,
        .next_full_gc_ratio = 4,
    },
};
