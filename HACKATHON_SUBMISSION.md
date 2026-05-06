# WorkflowDef Preflight for NullBoiler

## Problem discovered

NullBoiler consumes file-based tracker/pull-mode workflow definitions through
`workflow_loader.loadWorkflows`. That loader intentionally keeps permissive
runtime behavior: missing directories return an empty map, invalid files are
skipped, and files with empty `pipeline_id` are ignored.

That behavior is useful at runtime, but it makes workflow authoring harder.
Developers can make a typo in JSON, forget `pipeline_id`, or accidentally reuse a
pipeline mapping and only discover it after the server starts.

## Chosen solution

Add `nullboiler validate-workflows [PATH]`, a local CLI preflight command for the
same file-based `WorkflowDef` JSON files consumed by `loadWorkflows`.

The command reports actionable diagnostics before the server starts while
preserving the existing runtime loader semantics.

## Why this idea was chosen

This idea had the best developer-impact-to-complexity ratio among the options
found during repository exploration. NullClaw is broad and central, NullHub
changes often span backend and UI, and NullWatch already has a strong CLI. In
NullBoiler, workflow files are a core developer touchpoint, and a focused
preflight command is easy to demo, review, and merge without a large refactor.

## What was implemented

- Added a structured workflow-file validation helper in `src/workflow_loader.zig`.
- Added `validate-workflows [PATH]` CLI routing in `src/main.zig`.
- Added help output for the new command.
- Added human-readable diagnostics with separate errors and warnings.
- Added unit tests for valid files, malformed JSON, missing or empty
  `pipeline_id`, duplicate `pipeline_id`, missing directories, and warning-only
  shapes.
- Documented the new command in `README.md`.

## Files changed

- `src/main.zig`
- `src/workflow_loader.zig`
- `README.md`
- `HACKATHON_SUBMISSION.md`

## How to test or demo it

```bash
zig build test --summary all
zig build run -- validate-workflows
zig build run -- validate-workflows workflows
```

To demo errors, create a temporary workflow directory with malformed JSON or two
files that use the same `pipeline_id`, then run:

```bash
zig build run -- validate-workflows /path/to/temp/workflows
```

Expected behavior:

- no errors exits with status `0`
- one or more errors exits with status `1`
- warnings are printed but do not fail the command

## Limitations and future improvements

- The command validates only file-based tracker/pull-mode `WorkflowDef` files,
  not every workflow format exposed by NullBoiler's HTTP graph workflow API.
- The validator scans direct `*.json` children of the target directory, matching
  `loadWorkflows`; it does not recurse into nested example directories.
- Future work could add machine-readable JSON output for CI integrations.
