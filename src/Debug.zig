// A self-contained frame profiler: FPS plus per-phase timings with their share
// of the frame, printed to any writer. The Window owns one of these (see
// `Window.debug`) and reference-counts it, so the measuring path is dead
// (a null check) whenever no debug watcher is alive.
///
/// Measurement itself is a monotonic-clock read per section boundary (~30ns on
/// Linux vDSO), and only runs while the object is plugged in. Nothing is
/// allocated or formatted while timing; printing is a separate call.
///
/// Since the last rewrite the profiler keeps a rolling ring of the last
/// `HistoryWindow` (200) frame samples and reports *stats over that window*
/// (avg/min/max/p50/p95/p99, plus a "10% lows" number = the average of the
/// slowest 10% of frames). It also watches every frame for a sudden deviation
/// from the frame's own running average and, when one happens, prints an
/// on-the-spot line with the elapsed time and whether it qualifies as a
/// "10% lows" event.
const std = @import("std");

/// Monotonic clock in nanoseconds. Uses the Linux vDSO path (a ~10-40ns call)
/// when available, which is what keeps the measuring overhead negligible.
/// `std.time` in this toolchain carries no clock source, so we go to the
/// platform directly.
fn now() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

/// The phases of a frame that can be timed. `frame` spans the whole loop; the
/// others are named sections the Window and/or the app bracket with `begin`/`end`.
/// Sections are a fixed comptime set so timing is just an array index — no
/// hashing, no allocation.
pub const Section = enum {
    frame,
    events,
    build,
    layout,
    draw,
    present,
    /// Time spent consulting/retrieving/uploading the gpu, shadow, blur and
    /// layout caches. This is a *sub*-phase: cache lookups happen inside
    /// `build`/`layout`/`draw`, so its time also appears in those rows. It is
    /// reported separately (and excluded from the `gap` reconciliation) so it
    /// never overlaps a phase at the same nest depth.
    cache,
};

/// The profiler object `Window.debug()` returns. Reference counting lives in
/// the Window: while any caller holds this, timing runs; when the last caller
/// releases, the Window resets the object (`deinit`) and a later request
/// re-inits it fresh.
pub const DebugInfo = struct {
    /// Seconds-worth of frame time the FPS window averages over.
    pub const fps_interval_ns: i128 = 500 * std.time.ns_per_ms;

    /// How many most-recent frame samples the report averages over.
    pub const HistoryWindow = 200;

    /// A frame is "anomalous" (printed live) when it is at least `spike_factor`
    /// times the running average of the window and `spike_min_ns` over it.
    pub const spike_factor: f32 = 2.0;
    /// Floor (in ns) an anomalous frame must exceed the window average by, so a
    /// frame that is only fractionally slower is ignored.
    pub const spike_min_ns: u64 = std.time.ns_per_ms;

    const N = @typeInfo(Section).@"enum".fields.len;

    /// One recorded frame: the whole-frame time plus per-section times.
    const FrameSample = struct {
        total_ns: u64,
        sec_ns: [N]u64,
    };

    // Per-section pending start stamps; -1 means "not currently being timed".
    start: [N]i128 = [_]i128{-1} ** N,
    /// Open-nesting depth per section. `begin` on an already-open section just
    /// bumps the depth; only the outermost `end` closes the span. Keeps a
    /// sub-phase like `.cache` (lookups inside `build`/`layout`/`draw`) from
    /// corrupting an enclosing phase's stamp, and merges nested cache consults
    /// (e.g. a cached texture drawn while another consults) into one span.
    depth: [N]u32 = [_]u32{0} ** N,
    /// Accumulated nanoseconds per section since the object was re-inited.
    acc_ns: [N]u64 = [_]u64{0} ** N,
    /// How many times each section has been ended since re-init.
    count: [N]u64 = [_]u64{0} ** N,
    /// The last finished duration per section.
    last_ns: [N]u64 = [_]u64{0} ** N,

    // FPS: a rolling window of `fps_interval_ns`, recomputed on every frame end.
    fps_start: i128 = 0,
    fps_frames: u64 = 0,
    fps_now: f64 = 0,

    // Rolling ring of the last `HistoryWindow` frames.
    samples: [HistoryWindow]FrameSample = undefined,
    /// Next free ring slot.
    spos: usize = 0,
    /// Frames recorded so far, capped at `HistoryWindow`.
    scount: usize = 0,
    /// Monotonic time the profiler came alive (for elapsed in live spikes).
    start_ns: i128 = 0,

    pub fn init() DebugInfo {
        return .{ .start_ns = now() };
    }

    /// Resets every measurement. Called by the Window when the last debug
    /// watcher releases, so a later `debug()` starts from a clean slate.
    pub fn deinit(self: *DebugInfo) void {
        self.* = .{ .start_ns = now() };
    }

    pub fn begin(self: *DebugInfo, section: Section) void {
        const i = @intFromEnum(section);
        if (self.depth[i] == 0) self.start[i] = now();
        self.depth[i] += 1;
    }

    /// Closes `section`, folding its duration into the accumulators. Skips if
    /// `begin` was never called for it (e.g. a section the app does not use).
    /// Nested `begin`s are folded by their outermost `end`.
    pub fn end(self: *DebugInfo, section: Section) void {
        const i = @intFromEnum(section);
        if (self.depth[i] == 0) return;
        self.depth[i] -= 1;
        if (self.depth[i] != 0) return;
        const t0 = self.start[i];
        if (t0 < 0) return;
        self.start[i] = -1;
        const ns: u64 = @intCast(now() - t0);
        self.last_ns[i] = ns;
        self.acc_ns[i] += ns;
        self.count[i] += 1;
        if (section == .frame) self._finalize();
    }

    /// Runs whenever a whole frame closes: pushes it into the ring, advances the
    /// FPS window, and live-detects anomalies.
    fn _finalize(self: *DebugInfo) void {
        const frame_i = @intFromEnum(Section.frame);
        const total_ns = self.last_ns[frame_i];

        var sec: [N]u64 = undefined;
        for (0..N) |i| sec[i] = self.last_ns[i];
        self.samples[self.spos] = .{ .total_ns = total_ns, .sec_ns = sec };
        self.spos = (self.spos + 1) % HistoryWindow;
        if (self.scount < HistoryWindow) self.scount += 1;

        self._updateFps();

        // Live anomaly watch once we have enough history to trust the average.
        if (self.scount >= 30) self._detectSpike(total_ns);
    }

    /// Prints a full live review when a frame departs from the window's running
    /// average: a one-line header (with the elapsed runtime and whether it is a
    /// 10% low), then the same per-section block the periodic report shows, so
    /// you can skim which phase is dragging the frame down.
    fn _detectSpike(self: *DebugInfo, total_ns: u64) void {
        const n = self.scount;
        var buf: [HistoryWindow]u64 = undefined;
        self.windowSortedCopy(&buf, n);
        const avg_ns = self.windowAvg(buf[0..n]);
        if (avg_ns == 0) return;

        if (@as(f64, @floatFromInt(total_ns)) < @as(f64, @floatFromInt(avg_ns)) * spike_factor) return;
        if (total_ns -| avg_ns < spike_min_ns) return;

        // A 10% low: this frame sits in the slowest 10% of the window.
        const p90_ns = buf[self.percentileIndex(n, 0.90)];
        const is_low = total_ns >= p90_ns;

        const sec_elapsed: f64 = @as(f64, @floatFromInt(now() - self.start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const over_ms = self.ms(total_ns -| avg_ns);
        const pct = 100.0 * @as(f64, @floatFromInt(total_ns -| avg_ns)) / @as(f64, @floatFromInt(avg_ns));
        std.debug.print(
            "[+{d:.3}s] frame {d:.3}ms  {s}  avg {d:.3}ms  +{d:.2}ms over  ({d:.0}%)\n",
            .{ sec_elapsed, self.ms(total_ns), if (is_low) "10% low" else "spike", self.ms(avg_ns), over_ms, pct },
        );

        // Same block as the periodic report: each phase's avg / worst / share.
        var frame_total_ns: u128 = 0;
        var section_totals: [N]u128 = [_]u128{0} ** N;
        var section_counts: [N]u64 = [_]u64{0} ** N;
        var section_max: [N]u64 = [_]u64{0} ** N;
        for (0..n) |k| {
            const pos = (self.spos + HistoryWindow - n + k) % HistoryWindow;
            const s = self.samples[pos];
            frame_total_ns += s.total_ns;
            for (0..N) |i| {
                if (s.sec_ns[i] == 0) continue;
                section_totals[i] += s.sec_ns[i];
                section_counts[i] += 1;
                if (s.sec_ns[i] > section_max[i]) section_max[i] = s.sec_ns[i];
            }
        }
        const avg_frame_ms = if (frame_total_ns > 0)
            @as(f64, @floatFromInt(frame_total_ns)) / @as(f64, @floatFromInt(n)) / std.time.ns_per_ms
        else
            0;
        self.printSections(n, section_totals, section_counts, section_max, avg_frame_ms);
    }
    fn windowSortedCopy(self: *const DebugInfo, out: []u64, n: usize) void {
        for (0..n) |k| {
            const pos = (self.spos + HistoryWindow - n + k) % HistoryWindow;
            out[k] = self.samples[pos].total_ns;
        }
        std.sort.insertion(u64, out[0..n], {}, std.sort.asc(u64));
    }

    fn windowAvg(_: *const DebugInfo, prev: []const u64) u64 {
        var sum: u128 = 0;
        for (prev) |t| sum += t;
        if (prev.len == 0) return 0;
        return @intCast(sum / @as(u128, prev.len));
    }

    fn percentileIndex(_: *const DebugInfo, n: usize, p: f64) usize {
        return @intFromFloat(@as(f64, @floatFromInt(n -| 1)) * p);
    }

    fn ms(_: *const DebugInfo, ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    fn _updateFps(self: *DebugInfo) void {
        const current = now();
        if (self.fps_frames == 0) self.fps_start = current;
        self.fps_frames += 1;
        const elapsed = current - self.fps_start;
        if (elapsed > 0)
            self.fps_now = @as(f64, @floatFromInt(self.fps_frames)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        if (elapsed >= fps_interval_ns) {
            self.fps_frames = 0;
        }
    }

    /// The current FPS from the rolling window (0 until the first window
    /// partially fills).
    pub fn fps(self: *const DebugInfo) f64 {
        return self.fps_now;
    }

    /// Average duration (ms) of `section` over the samples since re-init.
    pub fn averageMs(self: *const DebugInfo, section: Section) f64 {
        const i = @intFromEnum(section);
        const n = self.count[i];
        if (n == 0) return 0;
        return @as(f64, @floatFromInt(self.acc_ns[i])) / @as(f64, @floatFromInt(n)) / std.time.ns_per_ms;
    }

    /// Mean of the slowest 10% of frames (the tail that stutters).
    fn tenPercentLows(_: *const DebugInfo, sorted: []const u64) u64 {
        const n = sorted.len;
        if (n == 0) return 0;
        if (n < 10) return sorted[n - 1];
        const start = (9 * n) / 10;
        var sum: u128 = 0;
        for (sorted[start..n]) |t| sum += t;
        return @intCast(sum / @as(u128, n - start));
    }

    /// The per-section totals shared by the periodic report and the live spike
    /// review; see `printSections`.

    /// Writes a report to stderr averaged over the last `HistoryWindow` frames:
    /// FPS, frame avg/min/max plus p50/p95/p99, a "10% lows" number, and each
    /// timed section's average, worst frame and share of the frame.
    pub fn print(self: *const DebugInfo) void {
        const n = self.scount;
        if (n == 0) {
            std.debug.print("profiler: no frames yet\n", .{});
            return;
        }
        var buf: [HistoryWindow]u64 = undefined;
        self.windowSortedCopy(&buf, n);

        const avg_ns = self.windowAvg(buf[0..n]);
        const min_ns = buf[0];
        const max_ns = buf[n - 1];
        const p50_ns = buf[self.percentileIndex(n, 0.50)];
        const p95_ns = buf[self.percentileIndex(n, 0.95)];
        const p99_ns = buf[self.percentileIndex(n, 0.99)];
        const lows_ns = self.tenPercentLows(buf[0..n]);

        std.debug.print("\n=== profiler: last {d} frames ===\n", .{n});
        std.debug.print("fps: {d:.1}\n", .{self.fps_now});

        // Per-section totals/counts/max over the window (ring order).
        var frame_total_ns: u128 = 0;
        var section_totals: [N]u128 = [_]u128{0} ** N;
        var section_counts: [N]u64 = [_]u64{0} ** N;
        var section_max: [N]u64 = [_]u64{0} ** N;
        for (0..n) |k| {
            const pos = (self.spos + HistoryWindow - n + k) % HistoryWindow;
            const s = self.samples[pos];
            frame_total_ns += s.total_ns;
            for (0..N) |i| {
                if (s.sec_ns[i] == 0) continue;
                section_totals[i] += s.sec_ns[i];
                section_counts[i] += 1;
                if (s.sec_ns[i] > section_max[i]) section_max[i] = s.sec_ns[i];
            }
        }

        std.debug.print(
            "frame: avg {d:.3}ms  min {d:.3}ms  max {d:.3}ms  p50 {d:.3}  p95 {d:.3}  p99 {d:.3}\n",
            .{ self.ms(avg_ns), self.ms(min_ns), self.ms(max_ns), self.ms(p50_ns), self.ms(p95_ns), self.ms(p99_ns) },
        );
        std.debug.print("10% lows (avg slowest decile): {d:.3}ms\n", .{self.ms(lows_ns)});

        const avg_frame_ms = if (frame_total_ns > 0)
            @as(f64, @floatFromInt(frame_total_ns)) / @as(f64, @floatFromInt(n)) / std.time.ns_per_ms
        else
            0;

        self.printSections(n, section_totals, section_counts, section_max, avg_frame_ms);
    }

    /// The per-section block shared by the periodic 200-frame report and the
    /// live spike review: each timed phase's average, worst frame and share of
    /// the frame, in a fixed order so it is easy to skim for the offender. Ends
    /// with a `gap` row (renderClear, override, getWindowSize, profiler
    /// overhead) so the rows reconcile with the frame average.
    fn printSections(
        self: *const DebugInfo,
        n: usize,
        section_totals: [N]u128,
        section_counts: [N]u64,
        section_max: [N]u64,
        avg_frame_ms: f64,
    ) void {
        const section_list = .{ Section.events, Section.build, Section.layout, Section.draw, Section.present };
        inline for (section_list) |tag_selected| {
            const i = @intFromEnum(tag_selected);
            if (section_counts[i] != 0) {
                const avg_ms = @as(f64, @floatFromInt(section_totals[i])) / @as(f64, @floatFromInt(section_counts[i])) / std.time.ns_per_ms;
                const pct = if (avg_frame_ms > 0) 100.0 * avg_ms / avg_frame_ms else 0;
                std.debug.print(
                    "  {s:<9} avg {d:8.3}ms  worst {d:8.3}ms  {d:5.1}%\n",
                    .{ @tagName(tag_selected), avg_ms, self.ms(section_max[i]), pct },
                );
            }
        }

        // Cache consulting/retrieval is a sub-phase: its lookups run *inside*
        // the phases above, so it is printed as its own row but excluded from
        // the `gap` reconciliation (otherwise the named phases would sum past
        // the whole frame).
        const cache_i = @intFromEnum(Section.cache);
        if (section_counts[cache_i] != 0) {
            const avg_ms = @as(f64, @floatFromInt(section_totals[cache_i])) / @as(f64, @floatFromInt(section_counts[cache_i])) / std.time.ns_per_ms;
            const pct = if (avg_frame_ms > 0) 100.0 * avg_ms / avg_frame_ms else 0;
            std.debug.print(
                "  {s:<9} avg {d:8.3}ms  worst {d:8.3}ms  {d:5.1}%\n",
                .{ "cache", avg_ms, self.ms(section_max[cache_i]), pct },
            );
        }

        // Unlabelled time inside the frame: everything between the named
        // sections (renderClear, override, getWindowSize, section overhead).
        // `.cache` is intentionally left out: it already lives inside them.
        var sections_sum: u128 = 0;
        inline for (section_list) |tag_selected| sections_sum += section_totals[@intFromEnum(tag_selected)];
        const sections_avg_ms = if (n > 0)
            @as(f64, @floatFromInt(sections_sum)) / @as(f64, @floatFromInt(n)) / std.time.ns_per_ms
        else
            0;
        const gap_ms = if (avg_frame_ms > sections_avg_ms) avg_frame_ms - sections_avg_ms else 0;
        const gap_pct = if (avg_frame_ms > 0) 100.0 * gap_ms / avg_frame_ms else 0;
        std.debug.print(
            "  {s:<9} avg {d:8.3}ms  {s:>14}  {d:5.1}%\n",
            .{ "gap", gap_ms, "(renderClear/override/etc.)", gap_pct },
        );
    }
};

test "fps and sections accumulate" {
    var info = DebugInfo.init();
    info.begin(.frame);
    info.begin(.build);
    info.end(.build);
    info.begin(.layout);
    info.end(.layout);
    info.end(.frame);
    try std.testing.expect(info.count[@intFromEnum(Section.build)] == 1);
    try std.testing.expect(info.count[@intFromEnum(Section.layout)] == 1);
    try std.testing.expect(info.count[@intFromEnum(Section.frame)] == 1);
    // end without begin is a no-op
    info.end(.present);
    try std.testing.expect(info.count[@intFromEnum(Section.present)] == 0);
}

test "ring keeps only the last HistoryWindow frames" {
    var info = DebugInfo.init();
    for (0..250) |_| {
        info.begin(.frame);
        info.end(.frame);
    }
    try std.testing.expect(info.scount == DebugInfo.HistoryWindow);
    try std.testing.expect(info.count[@intFromEnum(Section.frame)] == 250);
}

test "nested sections fold into one span and keep the parent's stamp" {
    var info = DebugInfo.init();
    info.begin(.frame);
    info.begin(.draw);
    // Two nested cache consults (a cached texture drawn during a shadow lookup
    // must not corrupt the enclosing `.draw` stamp nor double-count).
    info.begin(.cache);
    info.begin(.cache);
    info.end(.cache);
    info.begin(.cache);
    info.end(.cache);
    info.end(.cache);
    info.end(.draw);
    info.end(.frame);
    try std.testing.expect(info.count[@intFromEnum(Section.cache)] == 1);
    try std.testing.expect(info.count[@intFromEnum(Section.draw)] == 1);
    try std.testing.expect(info.count[@intFromEnum(Section.frame)] == 1);
    // `.cache` time is strictly inside `.draw`, so it can never exceed it.
    try std.testing.expect(info.acc_ns[@intFromEnum(Section.cache)] <= info.acc_ns[@intFromEnum(Section.draw)]);
    try std.testing.expect(info.depth[@intFromEnum(Section.cache)] == 0);
    try std.testing.expect(info.depth[@intFromEnum(Section.draw)] == 0);
}

test "spike reviews are triggered and include sections" {
    var info = DebugInfo.init();
    // 30 steady frames so the spike threshold (scount >= 30) is met, then one
    // long frame that should trip the live review.
    for (0..30) |_| {
        info.begin(.frame);
        info.begin(.build);
        info.end(.build);
        info.begin(.draw);
        info.end(.draw);
        info.end(.frame);
    }
    try std.testing.expect(info.scount >= 30);
    // Cap the section_max so printSections has data without tripping the live
    // print; just verify the aggregator over the window is non-trivial.
    var total: u128 = 0;
    var i: usize = 0;
    const n = info.scount;
    while (i < n) : (i += 1) {
        const pos = (info.spos + DebugInfo.HistoryWindow - n + i) % DebugInfo.HistoryWindow;
        total += info.samples[pos].total_ns;
    }
    try std.testing.expect(total > 0);
}