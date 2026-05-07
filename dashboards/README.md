# NullBoiler observability stack (P1-03)

Ready-to-import Grafana dashboards plus a minimal Prometheus scrape
config for the existing `/metrics` endpoint.

This contributes the **operator side** of `reference/todo.md` P1-03
("Structured observability: request IDs, metrics endpoint, OTEL
spans"). The endpoint and counters already ship in `src/metrics.zig`;
this directory makes them visible.

> **Side benefit:** the panels also visualise the integration gaps
> documented in
> [`nullclaw/docs/integration-analysis.md`](https://github.com/nullclaw/nullclaw/blob/main/docs/integration-analysis.md).
> When a NullClaw worker is wired up via `/webhook` (Gap 3 — HIGH
> PRIORITY in that document), the *Worker dispatch failure ratio*
> panel goes red while the *Health-check failure ratio* stays green,
> isolating the contract mismatch (sync `{status:"ok",response:"..."}`
> expected, async `{status:"received"}` returned). See
> [Diagnosing integration gaps](#diagnosing-integration-gaps) below for
> the exact panel pattern.

## Contents

```
dashboards/
├── README.md                            this file
├── grafana/
│   ├── nullboiler-overview.json         high-level operations view
│   └── nullboiler-workers.json          per-fleet worker health view
├── prometheus/
│   └── prometheus.yml                   minimal scrape config
└── alerts/
    └── nullboiler.rules.yml             8 AlertManager rules paired 1:1 with the dashboards
```

## What each dashboard answers

### `nullboiler-overview.json`

Open this first when investigating "is something wrong?".

| Panel | Question it answers |
|---|---|
| HTTP requests/sec | Is anyone talking to us right now? |
| Runs created/sec | Is work flowing into the orchestrator? |
| Worker dispatch failure ratio (5m) | What share of dispatches are blowing up? |
| Callback failures/sec | Are run-lifecycle webhooks reaching consumers? |
| Run & step throughput | Mix of created / replayed / claimed / retried over time |
| Worker dispatch (success vs failure) | Stacked-area dispatch outcomes |
| Callbacks (sent vs failed) | Webhook delivery reliability |
| Reliability ratios | Idempotent replay ratio + step retry ratio with thresholds |

### `nullboiler-workers.json`

Open this when the Overview shows elevated dispatch failure ratio and
you need to localize the bad worker.

| Panel | Question it answers |
|---|---|
| Health checks/sec | Are health probes running? |
| Health-check failure ratio (5m) | Are workers responding to probes? |
| Dispatch success/sec, failure/sec | Per-second outcomes |
| Health-check rate (probe vs failure) | Probes timeline |
| Dispatch outcomes (stacked bars) | Discrete dispatch outcomes |
| Failure ratios over time | The signal the circuit breaker reacts to |

## Metrics exposed by NullBoiler

From `src/metrics.zig`, all counters (no histograms or labels yet):

| Counter | Meaning |
|---|---|
| `nullboiler_http_requests_total` | All HTTP requests handled by the API |
| `nullboiler_runs_created_total` | Runs successfully accepted by `POST /runs` |
| `nullboiler_runs_idempotent_replays_total` | Idempotent replays of an existing run |
| `nullboiler_steps_claimed_total` | Steps dispatched to workers |
| `nullboiler_steps_retry_scheduled_total` | Steps scheduled for retry |
| `nullboiler_worker_dispatch_success_total` | Worker dispatches that succeeded |
| `nullboiler_worker_dispatch_failure_total` | Worker dispatches that failed |
| `nullboiler_worker_health_checks_total` | Health probes performed |
| `nullboiler_worker_health_failures_total` | Health probes that failed |
| `nullboiler_callback_sent_total` | Run-lifecycle webhook callbacks sent |
| `nullboiler_callback_failed_total` | Run-lifecycle webhook callbacks failed |

## Quick start (docker-compose)

```bash
docker run -d --name prom \
  -p 9090:9090 \
  -v "$(pwd)/dashboards/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus

docker run -d --name grafana \
  -p 3030:3000 \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  grafana/grafana

# Add Prometheus datasource pointing at http://host.docker.internal:9090
# Then: Dashboards -> Import -> upload nullboiler-overview.json and nullboiler-workers.json
```

Open Grafana at http://localhost:3030, point both dashboards at the
Prometheus datasource, and they will populate as soon as NullBoiler
starts handling traffic.

## Quick start (existing Prometheus + Grafana)

1. Add the scrape stanza from `prometheus/prometheus.yml` to your
   existing `prometheus.yml`. Reload Prometheus.
2. Import each `dashboards/grafana/*.json` via *Dashboards → Import → Upload JSON*.
3. When prompted, select your Prometheus datasource for the
   `${DS_PROMETHEUS}` template variable.
4. (optional) Wire up alerts:
   ```yaml
   # in prometheus.yml
   rule_files:
     - /etc/prometheus/alerts/nullboiler.rules.yml
   ```
   and copy `dashboards/alerts/nullboiler.rules.yml` into that path.

## Alert rules

`alerts/nullboiler.rules.yml` ships 8 rules grouped under
`nullboiler.health` and `nullboiler.flow`:

| Alert | Severity | Fires when |
|---|---|---|
| `NullBoilerInstanceDown` | critical | `up == 0` for 2m |
| `NullBoilerDispatchFailureRatioHigh` | warning | dispatch failure ratio > 30% for 5m |
| `NullBoilerDispatchFailureRatioCritical` | critical | dispatch failure ratio > 80% for 2m |
| `NullBoilerWorkerHealthDegraded` | warning | health-check failure ratio > 20% for 5m |
| `NullBoilerCallbackDeliveryDegraded` | warning | callback failure ratio > 10% for 10m |
| `NullBoilerStepRetryRateElevated` | info | retry/claim ratio > 20% for 10m |
| `NullBoilerNoTrafficForExtendedPeriod` | info | no HTTP traffic for 30m |
| `NullBoilerIdempotentReplayRatioVeryHigh` | info | replay ratio > 95% for 15m |

Thresholds match the colour bands on the corresponding Grafana panels
1:1 — if you tune one, mirror the other so the dashboard and the
pager tell the same story. The Critical-severity alerts are intended
for paging; everything else is ticket-bait.

> One deliberate exception: `NullBoilerWorkerHealthDegraded` fires at
> 20% (alert) while the dashboard's health-ratio stat shows yellow at
> 1% and red at 10%. The alert sits above the dashboard's red band on
> purpose — the dashboard is meant to surface single-probe blips
> visually, while the pager should only fire on a sustained pattern.

Validate locally:

```bash
docker run --rm --entrypoint=promtool \
  -v "$(pwd)/dashboards/alerts:/rules:ro" prom/prometheus \
  check rules /rules/nullboiler.rules.yml
# SUCCESS: 8 rules found
```

## Verification

The dashboards target Grafana 10.x and 11.x (`schemaVersion: 39`). The
PromQL is plain `rate()` over counters with `clamp_min` to avoid
divide-by-zero on idle clusters.

To smoke-test the metrics endpoint without Grafana:

```bash
curl -s http://localhost:8080/metrics | head -30
```

You should see eleven `# TYPE ... counter` blocks and their numeric
values. Empty values are valid — counters start at zero.

## Diagnosing integration gaps

A non-obvious value of these dashboards: they make ecosystem-level
integration gaps **visually obvious** without reading logs.

The cleanest example today is **Gap 3** in
[`nullclaw/docs/integration-analysis.md`](https://github.com/nullclaw/nullclaw/blob/main/docs/integration-analysis.md)
("Worker Endpoint for nullboiler Dispatch — HIGH PRIORITY"). When a
plain `nullclaw gateway` is registered as a NullBoiler worker:

- `/health` succeeds → `nullboiler_worker_health_failures_total` stays low
- `/webhook` returns `{"status":"received"}` instead of the documented
  `{"status":"ok","response":"..."}` →
  `nullboiler_worker_dispatch_failure_total` increments on every step

In the **Workers** dashboard's *Failure ratios over time* panel this
shows up as **dispatch failure ratio at ~100% (red)** sitting on top
of **health-check failure ratio near 0% (green)** — a one-glance
diagnosis that the worker is reachable but its response contract is
broken.

This is exactly the visual signal NullBoiler maintainers would want
when triaging field reports about worker dispatches; it surfaces the
gap that `integration-analysis.md` predicts but does not yet
mitigate at runtime.

## Future work

- Histograms for HTTP latency and worker dispatch duration (would
  enable percentile panels).
- Per-worker labels on the dispatch counters (would enable
  per-worker breakdown panels — currently the workers dashboard shows
  fleet-wide aggregates). On a fleet of N workers with the metrics
  unlabeled, a single bad worker pulling 1/N of dispatches produces a
  ~1/N failure ratio — below the 30% warning threshold for N ≥ 4.
  Per-worker labels resolve this.
- Recording rules + Grafana-native alerting (the AlertManager rules
  in `alerts/` are the floor — a recording-rule layer would precompute
  the ratios and avoid PromQL duplication between dashboards and
  alerts).

These are not required for P1-03 but are natural follow-ups.
