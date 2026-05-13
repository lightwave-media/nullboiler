# NullBoiler HTTP API

This directory hosts the HTTP API contract for NullBoiler.

- **Source of truth:** [`docs/openapi.yaml`](../openapi.yaml) — OpenAPI 3.1
- **Maintainer roadmap reference:** [`reference/todo.md` P2-04](../../reference/todo.md)

The spec covers all 36 HTTP operations exposed by `src/api.zig` and all
domain types from `src/types.zig`.

## At a glance

| Group | Endpoints |
|---|---|
| Health, Metrics | `GET /health`, `GET /metrics` |
| Runs | `POST /runs`, `GET /runs`, `GET /runs/{id}`, `POST /runs/{id}/{cancel,retry,resume,replay,state}`, `POST /runs/fork` |
| Steps & Events | `GET /runs/{id}/steps`, `GET /runs/{id}/steps/{step_id}`, `GET /runs/{id}/events`, `GET /runs/{id}/stream` (JSON stream snapshot) |
| Checkpoints | `GET /runs/{id}/checkpoints`, `GET /runs/{id}/checkpoints/{cp_id}` |
| Workers | `POST /workers`, `GET /workers`, `DELETE /workers/{id}` |
| Workflows | full CRUD on `/workflows`, plus `validate`, `mermaid`, `run` |
| Tracker bridge | `GET /tracker/{status,tasks,stats,tasks/{id}}`, `POST /tracker/refresh` |
| Admin | `POST /admin/drain`, `GET /rate-limits` |
| Internal | `POST /internal/agent-events/{run_id}/{step_id}` (worker callback) |

## Quick start

### View the spec

```bash
# Redoc (no install — uses npx)
npx @redocly/cli preview-docs docs/openapi.yaml

# Swagger UI (Docker)
docker run --rm -p 8088:8080 \
  -e SWAGGER_JSON=/spec/openapi.yaml \
  -v "$(pwd)/docs:/spec" \
  swaggerapi/swagger-ui
# then open http://localhost:8088
```

### Validate locally

```bash
# Python
python -m pip install openapi-spec-validator
python -m openapi_spec_validator docs/openapi.yaml

# Node
npx @apidevtools/swagger-cli validate docs/openapi.yaml

# Redocly (also runs lint rules beyond bare OpenAPI)
npx @redocly/cli lint docs/openapi.yaml
```

### Generate client SDKs

The spec is suitable for `openapi-generator-cli`. Recommended targets and
generators:

```bash
# TypeScript (fetch-based, browser & node)
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi.yaml \
  -g typescript-fetch \
  -o sdks/typescript-fetch \
  --additional-properties=npmName=@nullboiler/client,supportsES6=true,typescriptThreePlus=true

# Python (httpx async + sync)
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi.yaml \
  -g python \
  -o sdks/python \
  --additional-properties=packageName=nullboiler_client,projectName=nullboiler-client

# Go
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi.yaml \
  -g go \
  -o sdks/go \
  --additional-properties=packageName=nullboiler,withGoMod=true
```

For first-class language coverage we recommend publishing each SDK from
its own repository (e.g. `nullboiler/nullboiler-ts-sdk`) and pinning a
spec version per release tag.

## Conventions

- **Ids** — opaque strings; do not parse (currently 22-char ULIDs but
  this is not part of the contract).
- **Timestamps** — `*_ms` fields are milliseconds since the Unix epoch
  (UTC), `int64`.
- **Errors** — every 4xx/5xx response uses the same envelope:
  ```json
  {"error": {"code": "<code>", "message": "<human readable>"}}
  ```
  See `ErrorDetail.code` for the closed enum of codes.
- **Idempotency** — `POST /runs` honors `Idempotency-Key` (preferred) or
  `idempotency_key` body field. Stored-workflow launches via
  `POST /workflows/{id}/run` do not currently implement idempotency.
- **Auth** — bearer token; `/health` and `/metrics` are public so that
  load balancers and Prometheus scrapers can reach them without
  provisioning a token.

## Versioning the spec

The spec carries the same `info.version` as `GET /health` returns. When
the API surface changes:

1. Update `src/api.zig` and the matching tests.
2. Update `docs/openapi.yaml` and bump `info.version` in lockstep with
   the next NullBoiler release.
3. Re-run `python -m openapi_spec_validator docs/openapi.yaml` (or the
   Node equivalent) before committing.
4. Regenerate any vendored SDKs you ship.

A future enhancement (P2-03 in `reference/todo.md`) is to validate the
spec against a running orchestrator in CI by hitting every endpoint with
a smoke client.

## Provenance

This spec was authored from the source of truth files on the `main`
branch:

- `src/api.zig` — route table (`handleRequest`) and per-handler bodies
- `src/types.zig` — all enums and DB row types
- `src/strategy.zig` — strategy expansion semantics
- `src/workflow_validation.zig` and `src/engine.zig` — graph workflow shape
  and validation rules
- `src/metrics.zig` — Prometheus exposition (used in `/metrics` example)

If you change one of those files, update this spec. CI does not yet
diff them, so the discipline is currently social.
