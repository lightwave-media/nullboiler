const std = @import("std");

pub const Metrics = struct {
    http_requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    runs_created_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    runs_idempotent_replays_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steps_claimed_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steps_retry_scheduled_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_dispatch_success_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_dispatch_failure_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_health_checks_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worker_health_failures_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    callback_sent_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    callback_failed_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn incr(counter: *std.atomic.Value(u64)) void {
        _ = counter.fetchAdd(1, .monotonic);
    }

    pub fn renderPrometheus(self: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        return self.renderPrometheusWithGauges(allocator, null);
    }

    pub const GaugeSnapshot = struct {
        runs_in_flight: i64,
        steps_in_flight: i64,
        workers_healthy: i64,
        drain_mode: i64,
    };

    pub fn renderPrometheusWithGauges(
        self: *const Metrics,
        allocator: std.mem.Allocator,
        gauges: ?GaugeSnapshot,
    ) ![]const u8 {
        if (gauges) |g| {
            return std.fmt.allocPrint(
                allocator,
                \\# TYPE nullboiler_http_requests_total counter
                \\nullboiler_http_requests_total {d}
                \\# TYPE nullboiler_runs_created_total counter
                \\nullboiler_runs_created_total {d}
                \\# TYPE nullboiler_runs_idempotent_replays_total counter
                \\nullboiler_runs_idempotent_replays_total {d}
                \\# TYPE nullboiler_steps_claimed_total counter
                \\nullboiler_steps_claimed_total {d}
                \\# TYPE nullboiler_steps_retry_scheduled_total counter
                \\nullboiler_steps_retry_scheduled_total {d}
                \\# TYPE nullboiler_worker_dispatch_success_total counter
                \\nullboiler_worker_dispatch_success_total {d}
                \\# TYPE nullboiler_worker_dispatch_failure_total counter
                \\nullboiler_worker_dispatch_failure_total {d}
                \\# TYPE nullboiler_worker_health_checks_total counter
                \\nullboiler_worker_health_checks_total {d}
                \\# TYPE nullboiler_worker_health_failures_total counter
                \\nullboiler_worker_health_failures_total {d}
                \\# TYPE nullboiler_callback_sent_total counter
                \\nullboiler_callback_sent_total {d}
                \\# TYPE nullboiler_callback_failed_total counter
                \\nullboiler_callback_failed_total {d}
                \\# TYPE nullboiler_runs_in_flight gauge
                \\nullboiler_runs_in_flight {d}
                \\# TYPE nullboiler_steps_in_flight gauge
                \\nullboiler_steps_in_flight {d}
                \\# TYPE nullboiler_workers_healthy gauge
                \\nullboiler_workers_healthy {d}
                \\# TYPE nullboiler_drain_mode gauge
                \\nullboiler_drain_mode {d}
                \\
            ,
                .{
                    self.http_requests_total.load(.monotonic),
                    self.runs_created_total.load(.monotonic),
                    self.runs_idempotent_replays_total.load(.monotonic),
                    self.steps_claimed_total.load(.monotonic),
                    self.steps_retry_scheduled_total.load(.monotonic),
                    self.worker_dispatch_success_total.load(.monotonic),
                    self.worker_dispatch_failure_total.load(.monotonic),
                    self.worker_health_checks_total.load(.monotonic),
                    self.worker_health_failures_total.load(.monotonic),
                    self.callback_sent_total.load(.monotonic),
                    self.callback_failed_total.load(.monotonic),
                    g.runs_in_flight,
                    g.steps_in_flight,
                    g.workers_healthy,
                    g.drain_mode,
                },
            );
        }

        return std.fmt.allocPrint(
            allocator,
            \\# TYPE nullboiler_http_requests_total counter
            \\nullboiler_http_requests_total {d}
            \\# TYPE nullboiler_runs_created_total counter
            \\nullboiler_runs_created_total {d}
            \\# TYPE nullboiler_runs_idempotent_replays_total counter
            \\nullboiler_runs_idempotent_replays_total {d}
            \\# TYPE nullboiler_steps_claimed_total counter
            \\nullboiler_steps_claimed_total {d}
            \\# TYPE nullboiler_steps_retry_scheduled_total counter
            \\nullboiler_steps_retry_scheduled_total {d}
            \\# TYPE nullboiler_worker_dispatch_success_total counter
            \\nullboiler_worker_dispatch_success_total {d}
            \\# TYPE nullboiler_worker_dispatch_failure_total counter
            \\nullboiler_worker_dispatch_failure_total {d}
            \\# TYPE nullboiler_worker_health_checks_total counter
            \\nullboiler_worker_health_checks_total {d}
            \\# TYPE nullboiler_worker_health_failures_total counter
            \\nullboiler_worker_health_failures_total {d}
            \\# TYPE nullboiler_callback_sent_total counter
            \\nullboiler_callback_sent_total {d}
            \\# TYPE nullboiler_callback_failed_total counter
            \\nullboiler_callback_failed_total {d}
            \\
        ,
            .{
                self.http_requests_total.load(.monotonic),
                self.runs_created_total.load(.monotonic),
                self.runs_idempotent_replays_total.load(.monotonic),
                self.steps_claimed_total.load(.monotonic),
                self.steps_retry_scheduled_total.load(.monotonic),
                self.worker_dispatch_success_total.load(.monotonic),
                self.worker_dispatch_failure_total.load(.monotonic),
                self.worker_health_checks_total.load(.monotonic),
                self.worker_health_failures_total.load(.monotonic),
                self.callback_sent_total.load(.monotonic),
                self.callback_failed_total.load(.monotonic),
            },
        );
    }
};
