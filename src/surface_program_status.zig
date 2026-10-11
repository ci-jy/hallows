//! The program status records (OSC 7501) of one surface.
//!
//! Specification: https://www.superlogical.com/rex/docs/build/program-status
//!
//! The parser validates each report and leaves keeping records to the
//! terminal. This keeps one record per id, applies the lifetime rules of
//! the specification, and picks the record the surface should show.
//!
//! A record keeps the validated body of the report that last addressed
//! it, so everything about the record is read with the parser's
//! `Report` API.
const ProgramStatus = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal/main.zig");

const osc_program_status = terminal.osc.program_status;
pub const Report = osc_program_status.Report;
pub const State = osc_program_status.State;
pub const Kind = osc_program_status.Kind;

/// The most records a surface keeps. This is the limit in the
/// specification. A report that would create one more removes the
/// record that was updated least recently.
pub const max_records = 256;

/// The records, keyed by id. The root record has the empty id. Keys and
/// report bodies are owned.
records: std.StringArrayHashMapUnmanaged(Record) = .empty,

/// Incremented on every update, to order records by recency.
seq: u64 = 0,

const Record = struct {
    state: State,

    /// The validated body of the report that last addressed this record.
    data: []const u8,

    /// The value of `seq` when this record was last updated.
    seq: u64,

    fn report(self: Record) Report {
        return .{ .state = self.state, .data = self.data };
    }
};

/// The record a surface shows: the most urgent one, and of those the
/// one updated most recently.
pub const Summary = struct {
    report: Report,

    /// The `app` of the record, inherited from its nearest ancestor if
    /// the record has none.
    app: ?[]const u8,
};

pub fn deinit(self: *ProgramStatus, alloc: Allocator) void {
    var it = self.records.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.data);
    }
    self.records.deinit(alloc);
}

/// Apply a report. Returns the state the addressed record had before,
/// or null if there was no such record or the report was a `clear`.
pub fn apply(
    self: *ProgramStatus,
    alloc: Allocator,
    report: Report,
) Allocator.Error!?State {
    const id = report.readOption(.id) orelse "";

    if (report.state == .clear) {
        // Without an id, this removes every record. With one, it removes
        // that record and every record beneath it.
        if (id.len == 0) {
            self.reset(alloc);
        } else {
            _ = self.removeWhere(alloc, id, isSelfOrDescendant);
        }

        return null;
    }

    const data = try alloc.dupe(u8, report.data);
    errdefer alloc.free(data);
    self.seq += 1;

    if (self.records.getPtr(id)) |record| {
        const previous = record.state;
        alloc.free(record.data);
        record.* = .{ .state = report.state, .data = data, .seq = self.seq };
        return previous;
    }

    if (self.records.count() >= max_records) self.evictOldest(alloc);

    const key = try alloc.dupe(u8, id);
    errdefer alloc.free(key);
    try self.records.put(alloc, key, .{
        .state = report.state,
        .data = data,
        .seq = self.seq,
    });

    return null;
}

/// The program or the shell finished its work: the process exited or a
/// new shell prompt began. This drops the records that only make sense
/// while the program runs and keeps `done` and `error` for the user to
/// see. Returns true if any record was removed.
pub fn endWork(self: *ProgramStatus, alloc: Allocator) bool {
    return self.removeWhere(alloc, {}, struct {
        fn f(_: void, record: Record, _: []const u8) bool {
            return switch (record.state) {
                .idle, .working, .blocked => true,
                .done, .@"error", .clear => false,
            };
        }
    }.f);
}

/// The user has seen the surface, so the results that were waiting for
/// them are no longer news. Returns true if any record was removed.
pub fn acknowledge(self: *ProgramStatus, alloc: Allocator) bool {
    return self.removeWhere(alloc, {}, struct {
        fn f(_: void, record: Record, _: []const u8) bool {
            return switch (record.state) {
                .done, .@"error" => true,
                .idle, .working, .blocked, .clear => false,
            };
        }
    }.f);
}

/// Remove every record.
pub fn reset(self: *ProgramStatus, alloc: Allocator) void {
    var it = self.records.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.data);
    }
    self.records.clearRetainingCapacity();
}

/// The record to show, or null if there are no records.
pub fn summary(self: *const ProgramStatus) ?Summary {
    var best: ?Record = null;
    var best_id: []const u8 = "";
    var it = self.records.iterator();
    while (it.next()) |entry| {
        const record = entry.value_ptr.*;
        if (best) |b| {
            const u = urgency(record.state);
            const bu = urgency(b.state);
            if (u < bu or (u == bu and record.seq < b.seq)) continue;
        }

        best = record;
        best_id = entry.key_ptr.*;
    }

    const record = best orelse return null;
    const report = record.report();
    return .{
        .report = report,
        .app = report.readOption(.app) orelse self.inheritedApp(best_id),
    };
}

/// The `app` of the nearest ancestor of `id` that has one. The root
/// record is the ancestor of every other record.
pub fn inheritedApp(self: *const ProgramStatus, id: []const u8) ?[]const u8 {
    var parent = id;
    while (parent.len > 0) {
        parent = if (std.mem.lastIndexOfScalar(u8, parent, '/')) |i|
            parent[0..i]
        else
            "";

        const record = self.records.get(parent) orelse continue;
        if (record.report().readOption(.app)) |app| return app;
    }

    return null;
}

/// How much a state needs the user, from most to least: a program
/// waiting on the user, a failure, a finished result, ongoing work.
fn urgency(state: State) u8 {
    return switch (state) {
        .blocked => 4,
        .@"error" => 3,
        .done => 2,
        .working => 1,
        .idle, .clear => 0,
    };
}

fn isSelfOrDescendant(id: []const u8, _: Record, key: []const u8) bool {
    return std.mem.startsWith(u8, key, id) and
        (key.len == id.len or key[id.len] == '/');
}

fn removeWhere(
    self: *ProgramStatus,
    alloc: Allocator,
    ctx: anytype,
    comptime pred: fn (@TypeOf(ctx), Record, []const u8) bool,
) bool {
    var removed = false;

    // Iterate backwards because a swap remove moves the last entry,
    // which we've already visited, into the removed slot.
    var i = self.records.count();
    while (i > 0) {
        i -= 1;
        const key = self.records.keys()[i];
        const record = self.records.values()[i];
        if (!pred(ctx, record, key)) continue;
        self.records.swapRemoveAt(i);
        alloc.free(key);
        alloc.free(record.data);
        removed = true;
    }

    return removed;
}

fn evictOldest(self: *ProgramStatus, alloc: Allocator) void {
    const values = self.records.values();
    if (values.len == 0) return;
    var oldest: usize = 0;
    for (values, 0..) |record, i| {
        if (record.seq < values[oldest].seq) oldest = i;
    }

    const key = self.records.keys()[oldest];
    const data = values[oldest].data;
    self.records.swapRemoveAt(oldest);
    alloc.free(key);
    alloc.free(data);
}

/// Write `title` or `msg` of a report for showing outside the terminal
/// grid, such as in a notification or a tooltip. The parser already
/// refused control characters. This also removes text direction
/// overrides and other invisible formatting characters, as the
/// specification recommends, so a program can't disguise what the text
/// says.
pub fn writeDisplayText(
    report: Report,
    comptime option: osc_program_status.Option,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var buf: [osc_program_status.max_msg_bytes]u8 = undefined;
    var decoded: std.Io.Writer = .fixed(&buf);
    report.writeText(option, &decoded) catch unreachable;

    // The parser validated that the text is UTF-8.
    var it = (std.unicode.Utf8View.init(decoded.buffered()) catch unreachable).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch unreachable;
        if (isInvisibleFormat(cp)) continue;
        try writer.writeAll(slice);
    }
}

/// Text direction marks, embeddings, overrides, and isolates, and
/// zero-width characters.
fn isInvisibleFormat(cp: u21) bool {
    return switch (cp) {
        0x061C, // Arabic letter mark
        0x200B...0x200F, // zero-width space, joiners, LRM, RLM
        0x202A...0x202E, // embeddings and overrides
        0x2060...0x2069, // word joiner, invisible operators, isolates
        0xFEFF, // zero-width no-break space
        => true,
        else => false,
    };
}

const testing = std.testing;

fn testReport(comptime body: []const u8) Report {
    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;" ++ body);
    const report = p.end('\x1b').?.program_status.report;

    // The report points into the parser, so give it a stable copy.
    const S = struct {
        var buf: [osc_program_status.max_body_bytes]u8 = undefined;
    };
    @memcpy(S.buf[0..report.data.len], report.data);
    return .{ .state = report.state, .data = S.buf[0..report.data.len] };
}

test "apply replaces records by id" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    try testing.expectEqual(null, try s.apply(alloc, testReport("state=working:app=cargo")));
    try testing.expectEqual(State.working, try s.apply(alloc, testReport("state=done")));
    try testing.expectEqual(1, s.records.count());

    // A report replaces its record completely, so the app is gone.
    const sum = s.summary().?;
    try testing.expectEqual(State.done, sum.report.state);
    try testing.expectEqual(null, sum.app);

    _ = try s.apply(alloc, testReport("state=working:id=a"));
    try testing.expectEqual(2, s.records.count());
}

test "clear removes a record and its descendants" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    _ = try s.apply(alloc, testReport("state=working"));
    _ = try s.apply(alloc, testReport("state=working:id=a"));
    _ = try s.apply(alloc, testReport("state=working:id=a/b"));
    _ = try s.apply(alloc, testReport("state=working:id=ab"));

    _ = try s.apply(alloc, testReport("state=clear:id=a"));
    try testing.expectEqual(2, s.records.count());
    try testing.expect(s.records.contains(""));
    try testing.expect(s.records.contains("ab"));

    _ = try s.apply(alloc, testReport("state=clear"));
    try testing.expectEqual(0, s.records.count());
    try testing.expectEqual(null, s.summary());
}

test "summary picks the most urgent, then most recent record" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    _ = try s.apply(alloc, testReport("state=working:app=deploy"));
    _ = try s.apply(alloc, testReport("state=blocked:kind=permission:id=us"));
    _ = try s.apply(alloc, testReport("state=done:id=eu"));

    var sum = s.summary().?;
    try testing.expectEqual(State.blocked, sum.report.state);
    try testing.expectEqualStrings("us", sum.report.readOption(.id).?);
    try testing.expectEqualStrings("deploy", sum.app.?);

    _ = try s.apply(alloc, testReport("state=blocked:kind=question:id=eu"));
    sum = s.summary().?;
    try testing.expectEqualStrings("eu", sum.report.readOption(.id).?);
}

test "app is inherited from the nearest ancestor" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    _ = try s.apply(alloc, testReport("state=working:app=root"));
    _ = try s.apply(alloc, testReport("state=working:id=a:app=mid"));
    try testing.expectEqualStrings("mid", s.inheritedApp("a/b/c").?);
    try testing.expectEqualStrings("root", s.inheritedApp("x/y").?);
    try testing.expectEqualStrings("root", s.inheritedApp("a").?);
    try testing.expectEqual(null, s.inheritedApp(""));
}

test "endWork keeps results and acknowledge removes them" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    _ = try s.apply(alloc, testReport("state=idle"));
    _ = try s.apply(alloc, testReport("state=working:id=w"));
    _ = try s.apply(alloc, testReport("state=blocked:id=b"));
    _ = try s.apply(alloc, testReport("state=done:id=d"));
    _ = try s.apply(alloc, testReport("state=error:id=e"));

    try testing.expect(s.endWork(alloc));
    try testing.expectEqual(2, s.records.count());
    try testing.expect(!s.endWork(alloc));

    try testing.expect(s.acknowledge(alloc));
    try testing.expectEqual(0, s.records.count());
    try testing.expect(!s.acknowledge(alloc));
}

test "too many records evicts the least recently updated" {
    const alloc = testing.allocator;
    var s: ProgramStatus = .{};
    defer s.deinit(alloc);

    var buf: [64]u8 = undefined;
    for (0..max_records) |i| {
        const body = try std.fmt.bufPrint(&buf, "state=working:id=r{d}", .{i});
        _ = try s.apply(alloc, .{ .state = .working, .data = body });
    }

    // Touch the first record so the second is now the oldest.
    _ = try s.apply(alloc, .{ .state = .working, .data = "state=working:id=r0" });
    _ = try s.apply(alloc, .{ .state = .working, .data = "state=working:id=new" });
    try testing.expectEqual(max_records, s.records.count());
    try testing.expect(s.records.contains("r0"));
    try testing.expect(!s.records.contains("r1"));
    try testing.expect(s.records.contains("new"));
}

test "writeDisplayText removes invisible formatting" {
    // "a\u{202E}b\u{200B}c" in base64.
    const report = testReport("state=done:msg=YeKArmLigItj");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDisplayText(report, .msg, &w);
    try testing.expectEqualStrings("abc", w.buffered());
}
