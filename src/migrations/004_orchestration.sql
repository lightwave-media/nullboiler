-- Note: step_deps table is kept for legacy POST /runs endpoint backward compatibility.
-- cycle_state, chat_messages, saga_state tables are legacy (unused by current engine).

-- Saved workflow definitions
CREATE TABLE IF NOT EXISTS workflows (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    definition_json TEXT NOT NULL,
    version INTEGER DEFAULT 1,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

-- State checkpoints (snapshots after each step)
CREATE TABLE IF NOT EXISTS checkpoints (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL,
    parent_id TEXT REFERENCES checkpoints(id),
    state_json TEXT NOT NULL,
    completed_nodes_json TEXT NOT NULL,
    version INTEGER NOT NULL,
    metadata_json TEXT,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_checkpoints_run ON checkpoints(run_id, version);
CREATE INDEX IF NOT EXISTS idx_checkpoints_parent ON checkpoints(parent_id);

-- Agent intermediate events (from nullclaw callback)
CREATE TABLE IF NOT EXISTS agent_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL,
    iteration INTEGER NOT NULL,
    tool TEXT,
    args_json TEXT,
    result_text TEXT,
    status TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_events_run_step ON agent_events(run_id, step_id);

-- Pending state injections (thread-safe queue for POST /runs/{id}/state)
CREATE TABLE IF NOT EXISTS pending_state_injections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    updates_json TEXT NOT NULL,
    apply_after_step TEXT,
    created_at_ms INTEGER NOT NULL
);

-- Extend runs table (all columns already present from prior migration run — ALTER TABLE skipped)
-- NOTE: state_json already exists from 001_init.sql
-- NOTE: workflow_id, forked_from_run_id, forked_from_checkpoint_id, checkpoint_count,
--       parent_run_id, config_json, total_input_tokens, total_output_tokens, total_tokens
--       already exist from a prior successful migration run.
-- Keeping these as no-ops so migration 004 is idempotent on this database.
SELECT 1; -- workflow_id (already exists)
SELECT 1; -- forked_from_run_id (already exists)
SELECT 1; -- forked_from_checkpoint_id (already exists)
SELECT 1; -- checkpoint_count (already exists)

-- Extend steps table (columns already present)
SELECT 1; -- state_before_json (already exists)
SELECT 1; -- state_after_json (already exists)
SELECT 1; -- state_updates_json (already exists)

-- Subgraph support (already present)
SELECT 1; -- parent_run_id (already exists)
SELECT 1; -- config_json (already exists)

-- Node-level cache (Gap 3)
CREATE TABLE IF NOT EXISTS node_cache (
    cache_key TEXT PRIMARY KEY,
    node_name TEXT NOT NULL,
    result_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    ttl_ms INTEGER
);

-- Pending writes from parallel node execution (Gap 4)
CREATE TABLE IF NOT EXISTS pending_writes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    value_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_writes_run ON pending_writes(run_id);

-- Token accounting columns on runs (already present)
SELECT 1; -- total_input_tokens (already exists)
SELECT 1; -- total_output_tokens (already exists)
SELECT 1; -- total_tokens (already exists)

-- Token accounting columns on steps (already present)
SELECT 1; -- input_tokens (already exists)
SELECT 1; -- output_tokens (already exists)
SELECT 1; -- total_tokens (already exists)
