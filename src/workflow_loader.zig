const std = @import("std");
const std_compat = @import("compat.zig");
const ids = @import("ids.zig");
const Store = @import("store.zig").Store;
const log = std.log.scoped(.workflow_loader);

// ── Types ─────────────────────────────────────────────────────────────

pub const ExecutionMode = enum {
    subprocess,
    dispatch,
};

pub const SubprocessConfig = struct {
    command: []const u8 = "nullclaw",
    args: []const []const u8 = &.{},
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
    continuation_prompt: ?[]const u8 = null,
};

pub const DispatchConfig = struct {
    worker_tags: []const []const u8 = &.{},
    protocol: []const u8 = "webhook",
};

pub const TransitionConfig = struct {
    transition_to: []const u8 = "",
    retry: bool = false,
};

pub const RetryConfig = struct {
    max_attempts: u32 = 3,
    backoff_base_ms: u32 = 10000,
    backoff_max_ms: u32 = 300000,
};

pub const WorkflowDef = struct {
    id: []const u8 = "",
    pipeline_id: []const u8 = "",
    claim_roles: []const []const u8 = &.{},
    execution: ExecutionMode = .subprocess,
    subprocess: SubprocessConfig = .{},
    dispatch: DispatchConfig = .{},
    prompt_template: ?[]const u8 = null,
    on_success: TransitionConfig = .{},
    on_failure: TransitionConfig = .{ .transition_to = "failed" },
    retry: ?RetryConfig = null,
};

pub const WorkflowMap = std.StringArrayHashMapUnmanaged(WorkflowDef);

pub const WorkflowDiagnosticSeverity = enum {
    @"error",
    warning,
};

pub const WorkflowDiagnostic = struct {
    severity: WorkflowDiagnosticSeverity,
    file_path: []const u8,
    message: []const u8,
    field: ?[]const u8 = null,
};

pub const WorkflowFileStatus = struct {
    file_path: []const u8,
    pipeline_id: []const u8,
    has_error: bool,
};

pub const WorkflowValidationResult = struct {
    checked_files: usize = 0,
    valid_files: usize = 0,
    error_count: usize = 0,
    warning_count: usize = 0,
    diagnostics: []WorkflowDiagnostic = &.{},
    files: []WorkflowFileStatus = &.{},
};

fn appendWorkflowDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(WorkflowDiagnostic),
    result: *WorkflowValidationResult,
    severity: WorkflowDiagnosticSeverity,
    file_path: []const u8,
    field: ?[]const u8,
    message: []const u8,
) !void {
    try diagnostics.append(allocator, .{
        .severity = severity,
        .file_path = file_path,
        .message = message,
        .field = field,
    });
    switch (severity) {
        .@"error" => result.error_count += 1,
        .warning => result.warning_count += 1,
    }
}

// ── loadWorkflows ─────────────────────────────────────────────────────

pub fn loadWorkflows(allocator: std.mem.Allocator, dir_path: []const u8) WorkflowMap {
    var map = WorkflowMap{};
    var dir = if (std.fs.path.isAbsolute(dir_path))
        std_compat.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return map
    else
        std_compat.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return map;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(WorkflowDef, allocator, contents, .{}) catch continue;
        const def = parsed.value;

        if (def.pipeline_id.len == 0) continue;

        map.put(allocator, def.pipeline_id, def) catch continue;
    }

    return map;
}

// ── validateWorkflowFiles ─────────────────────────────────────────────

/// Validate file-based tracker/pull-mode WorkflowDef JSON files without
/// changing loadWorkflows runtime semantics.
pub fn validateWorkflowFiles(allocator: std.mem.Allocator, dir_path: []const u8) !WorkflowValidationResult {
    var result = WorkflowValidationResult{};
    var diagnostics: std.ArrayListUnmanaged(WorkflowDiagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    var files: std.ArrayListUnmanaged(WorkflowFileStatus) = .empty;
    defer files.deinit(allocator);

    var seen_pipeline_files = std.StringHashMap([]const u8).init(allocator);
    defer seen_pipeline_files.deinit();

    var dir = if (std.fs.path.isAbsolute(dir_path))
        std_compat.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
            const path = try allocator.dupe(u8, dir_path);
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                path,
                null,
                "workflow directory is missing or unreadable",
            );
            result.files = try files.toOwnedSlice(allocator);
            result.diagnostics = try diagnostics.toOwnedSlice(allocator);
            return result;
        }
    else
        std_compat.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            const path = try allocator.dupe(u8, dir_path);
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                path,
                null,
                "workflow directory is missing or unreadable",
            );
            result.files = try files.toOwnedSlice(allocator);
            result.diagnostics = try diagnostics.toOwnedSlice(allocator);
            return result;
        };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        result.checked_files += 1;
        var file_has_error = false;
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        const contents = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                file_path,
                null,
                "workflow file is unreadable",
            );
            continue;
        };
        defer allocator.free(contents);

        const raw_json = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                file_path,
                null,
                "invalid workflow JSON",
            );
            continue;
        };
        raw_json.deinit();

        const parsed = std.json.parseFromSlice(WorkflowDef, allocator, contents, .{}) catch {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                file_path,
                null,
                "JSON does not match file-based WorkflowDef shape",
            );
            continue;
        };
        defer parsed.deinit();
        const def = parsed.value;

        if (def.pipeline_id.len == 0) {
            file_has_error = true;
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                file_path,
                "pipeline_id",
                "pipeline_id is missing or empty",
            );
        } else if (seen_pipeline_files.get(def.pipeline_id)) |first_file| {
            file_has_error = true;
            const msg = try std.fmt.allocPrint(
                allocator,
                "duplicate pipeline_id '{s}' also used by {s}",
                .{ def.pipeline_id, first_file },
            );
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .@"error",
                file_path,
                "pipeline_id",
                msg,
            );
        } else {
            try seen_pipeline_files.put(try allocator.dupe(u8, def.pipeline_id), file_path);
        }

        if (def.id.len == 0) {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .warning,
                file_path,
                "id",
                "id is empty",
            );
        }

        if (def.claim_roles.len == 0) {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .warning,
                file_path,
                "claim_roles",
                "claim_roles is empty",
            );
        }

        if (def.execution == .dispatch and def.dispatch.worker_tags.len == 0) {
            try appendWorkflowDiagnostic(
                allocator,
                &diagnostics,
                &result,
                .warning,
                file_path,
                "dispatch.worker_tags",
                "dispatch workflow has no worker_tags",
            );
        }

        if (!file_has_error) {
            result.valid_files += 1;
        }
        try files.append(allocator, .{
            .file_path = file_path,
            .pipeline_id = if (def.pipeline_id.len == 0) "" else try allocator.dupe(u8, def.pipeline_id),
            .has_error = file_has_error,
        });
    }

    if (result.checked_files == 0) {
        const path = try allocator.dupe(u8, dir_path);
        try appendWorkflowDiagnostic(
            allocator,
            &diagnostics,
            &result,
            .warning,
            path,
            null,
            "directory contains no JSON workflow files",
        );
    }

    result.files = try files.toOwnedSlice(allocator);
    result.diagnostics = try diagnostics.toOwnedSlice(allocator);
    return result;
}

test "loadWorkflows: supports absolute workflow directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "current.json",
        .data =
        \\{
        \\  "id": "wf-absolute",
        \\  "pipeline_id": "absolute",
        \\  "claim_roles": ["coder"],
        \\  "on_success": {"transition_to": "complete"}
        \\}
        ,
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expectEqualStrings("absolute", map.get("absolute").?.pipeline_id);
}

// ── WorkflowWatcher ──────────────────────────────────────────────────

pub const WorkflowWatcher = struct {
    dir_path: []const u8,
    store: *Store,
    last_check_ms: i64,
    file_hashes: std.StringHashMap(u64),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, dir_path: []const u8, store: *Store) WorkflowWatcher {
        return .{
            .dir_path = dir_path,
            .store = store,
            .last_check_ms = 0,
            .file_hashes = std.StringHashMap(u64).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *WorkflowWatcher) void {
        var it = self.file_hashes.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.file_hashes.deinit();
    }

    /// Check for changed workflow files. Called periodically from engine tick.
    pub fn checkForChanges(self: *WorkflowWatcher) void {
        const now = ids.nowMs();
        if (now - self.last_check_ms < 5000) return; // check every 5 seconds
        self.last_check_ms = now;

        var dir = if (std.fs.path.isAbsolute(self.dir_path))
            std_compat.fs.openDirAbsolute(self.dir_path, .{ .iterate = true }) catch return
        else
            std_compat.fs.cwd().openDir(self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const contents = dir.readFileAlloc(self.alloc, entry.name, 1024 * 1024) catch continue;
            defer self.alloc.free(contents);

            // Compute FNV1a hash of content
            const hash = std.hash.Fnv1a_64.hash(contents);

            // Check if hash changed
            const existing = self.file_hashes.get(entry.name);
            if (existing) |prev_hash| {
                if (prev_hash == hash) continue; // unchanged
            }

            // Parse and validate
            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, contents, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            const obj = parsed.value.object;

            // Extract name and id
            const wf_name = if (obj.get("name")) |v| (if (v == .string) v.string else null) else null;
            const wf_id = if (obj.get("id")) |v| (if (v == .string) v.string else null) else null;
            if (wf_id == null and wf_name == null) continue;

            const id = wf_id orelse wf_name.?;
            const name = wf_name orelse wf_id.?;

            // Upsert into workflows table
            // Try insert first; if it fails (duplicate id), update instead
            self.store.createWorkflow(id, name, contents) catch {
                self.store.updateWorkflow(id, name, contents) catch continue;
            };

            // Store hash (need to dupe the key since entry.name is transient)
            const key_dupe = self.alloc.dupe(u8, entry.name) catch continue;
            if (existing != null) {
                // Free old key if we're replacing
                if (self.file_hashes.fetchPut(key_dupe, hash) catch null) |old| {
                    self.alloc.free(old.key);
                }
            } else {
                self.file_hashes.put(key_dupe, hash) catch {
                    self.alloc.free(key_dupe);
                    continue;
                };
            }

            log.info("workflow {s} reloaded", .{id});
        }
    }
};

// ── getWorkflowForPipeline ────────────────────────────────────────────

pub fn getWorkflowForPipeline(map: *const WorkflowMap, pipeline_id: []const u8) ?*const WorkflowDef {
    return map.getPtr(pipeline_id);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "WorkflowDef defaults" {
    const def = WorkflowDef{};
    try std.testing.expectEqualStrings("", def.id);
    try std.testing.expectEqualStrings("", def.pipeline_id);
    try std.testing.expectEqual(@as(usize, 0), def.claim_roles.len);
    try std.testing.expectEqual(ExecutionMode.subprocess, def.execution);
    try std.testing.expectEqualStrings("nullclaw", def.subprocess.command);
    try std.testing.expectEqual(@as(usize, 0), def.subprocess.args.len);
    try std.testing.expectEqual(@as(u32, 20), def.subprocess.max_turns);
    try std.testing.expectEqual(@as(u32, 600000), def.subprocess.turn_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), def.dispatch.worker_tags.len);
    try std.testing.expectEqualStrings("webhook", def.dispatch.protocol);
    try std.testing.expectEqual(@as(?[]const u8, null), def.prompt_template);
    try std.testing.expectEqualStrings("", def.on_success.transition_to);
    try std.testing.expectEqualStrings("failed", def.on_failure.transition_to);
    try std.testing.expect(!def.on_failure.retry);
    try std.testing.expectEqual(@as(?RetryConfig, null), def.retry);
}

test "SubprocessConfig defaults" {
    const cfg = SubprocessConfig{};
    try std.testing.expectEqualStrings("nullclaw", cfg.command);
    try std.testing.expectEqual(@as(u32, 20), cfg.max_turns);
    try std.testing.expectEqual(@as(u32, 600000), cfg.turn_timeout_ms);
}

test "loadWorkflows: returns empty map when directory missing" {
    const map = loadWorkflows(std.testing.allocator, "nonexistent_workflow_dir_xyz_999");
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "loadWorkflows: loads JSON files from directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "code_review.json",
        .data =
        \\{
        \\  "id": "wf-code-review",
        \\  "pipeline_id": "code-review",
        \\  "claim_roles": ["reviewer"],
        \\  "execution": "subprocess",
        \\  "subprocess": {
        \\    "command": "nullclaw",
        \\    "max_turns": 10,
        \\    "turn_timeout_ms": 300000
        \\  },
        \\  "prompt_template": "Review this code: {{input.code}}",
        \\  "on_success": {"transition_to": "done"},
        \\  "on_failure": {"transition_to": "needs_review"}
        \\}
        ,
    });

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "deploy.json",
        .data =
        \\{
        \\  "id": "wf-deploy",
        \\  "pipeline_id": "deploy",
        \\  "claim_roles": ["deployer"],
        \\  "execution": "dispatch",
        \\  "dispatch": {
        \\    "worker_tags": ["deploy"],
        \\    "protocol": "webhook"
        \\  }
        \\}
        ,
    });

    // Non-json file should be ignored
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "readme.txt",
        .data = "not json",
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), map.count());

    const cr = map.get("code-review").?;
    try std.testing.expectEqualStrings("wf-code-review", cr.id);
    try std.testing.expectEqual(ExecutionMode.subprocess, cr.execution);
    try std.testing.expectEqualStrings("nullclaw", cr.subprocess.command);
    try std.testing.expectEqual(@as(u32, 10), cr.subprocess.max_turns);
    try std.testing.expectEqualStrings("Review this code: {{input.code}}", cr.prompt_template.?);
    try std.testing.expectEqualStrings("done", cr.on_success.transition_to);
    try std.testing.expectEqualStrings("needs_review", cr.on_failure.transition_to);

    const dep = map.get("deploy").?;
    try std.testing.expectEqualStrings("wf-deploy", dep.id);
    try std.testing.expectEqual(ExecutionMode.dispatch, dep.execution);
    try std.testing.expectEqual(@as(usize, 1), dep.dispatch.worker_tags.len);
    try std.testing.expectEqualStrings("deploy", dep.dispatch.worker_tags[0]);
}

test "loadWorkflows: skips files with empty pipeline_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "no_pipeline.json",
        .data =
        \\{"id": "wf-nope", "pipeline_id": ""}
        ,
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "getWorkflowForPipeline: returns pointer when found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = WorkflowMap{};
    map.put(alloc, "my-pipeline", WorkflowDef{
        .id = "wf-1",
        .pipeline_id = "my-pipeline",
    }) catch unreachable;

    const result = getWorkflowForPipeline(&map, "my-pipeline");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("wf-1", result.?.id);
}

test "getWorkflowForPipeline: returns null when not found" {
    var map = WorkflowMap{};
    const result = getWorkflowForPipeline(&map, "nonexistent");
    try std.testing.expectEqual(@as(?*const WorkflowDef, null), result);
}

test "parse workflow with retry config" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "id": "retry-wf",
        \\  "pipeline_id": "pipeline-retry",
        \\  "claim_roles": ["dev"],
        \\  "execution": "subprocess",
        \\  "retry": {
        \\    "max_attempts": 3,
        \\    "backoff_base_ms": 10000,
        \\    "backoff_max_ms": 300000
        \\  },
        \\  "on_failure": {
        \\    "transition_to": "failed",
        \\    "retry": true
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(WorkflowDef, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.retry != null);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.retry.?.max_attempts);
    try std.testing.expect(parsed.value.on_failure.retry);
}

test "parse workflow with continuation_prompt" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "id": "test-wf",
        \\  "pipeline_id": "pipeline-test",
        \\  "claim_roles": ["dev"],
        \\  "execution": "subprocess",
        \\  "subprocess": {
        \\    "command": "nullclaw",
        \\    "max_turns": 10,
        \\    "continuation_prompt": "Continue: attempt #{{attempt}}"
        \\  },
        \\  "prompt_template": "Do {{task.title}}"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(WorkflowDef, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Continue: attempt #{{attempt}}", parsed.value.subprocess.continuation_prompt.?);
}

test "validateWorkflowFiles: valid workflow directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "valid.json",
        .data =
        \\{
        \\  "id": "wf-valid",
        \\  "pipeline_id": "pipeline-valid",
        \\  "claim_roles": ["developer"]
        \\}
        ,
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 1), result.checked_files);
    try std.testing.expectEqual(@as(usize, 1), result.valid_files);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqual(@as(usize, 0), result.warning_count);
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("pipeline-valid", result.files[0].pipeline_id);
}

test "validateWorkflowFiles: malformed JSON is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "broken.json",
        .data = "{bad json",
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 1), result.checked_files);
    try std.testing.expectEqual(@as(usize, 1), result.error_count);
    try std.testing.expectEqualStrings("invalid workflow JSON", result.diagnostics[0].message);
}

test "validateWorkflowFiles: missing or empty pipeline_id is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "missing.json",
        .data = "{\"id\":\"wf-missing\",\"claim_roles\":[\"dev\"]}",
    });
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "empty.json",
        .data = "{\"id\":\"wf-empty\",\"pipeline_id\":\"\",\"claim_roles\":[\"dev\"]}",
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), result.checked_files);
    try std.testing.expectEqual(@as(usize, 2), result.error_count);
    for (result.diagnostics) |diag| {
        if (diag.severity == .@"error") {
            try std.testing.expectEqualStrings("pipeline_id", diag.field.?);
        }
    }
}

test "validateWorkflowFiles: duplicate pipeline_id is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "first.json",
        .data = "{\"id\":\"wf-a\",\"pipeline_id\":\"pipeline-dup\",\"claim_roles\":[\"dev\"]}",
    });
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "second.json",
        .data = "{\"id\":\"wf-b\",\"pipeline_id\":\"pipeline-dup\",\"claim_roles\":[\"reviewer\"]}",
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), result.checked_files);
    try std.testing.expectEqual(@as(usize, 1), result.error_count);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics[0].message, "duplicate pipeline_id") != null);
}

test "validateWorkflowFiles: missing directory is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), "nonexistent_workflow_dir_xyz_999");
    try std.testing.expectEqual(@as(usize, 0), result.checked_files);
    try std.testing.expectEqual(@as(usize, 1), result.error_count);
    try std.testing.expectEqualStrings("workflow directory is missing or unreadable", result.diagnostics[0].message);
}

test "validateWorkflowFiles: empty claim_roles is a warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "warn.json",
        .data = "{\"id\":\"wf-warn\",\"pipeline_id\":\"pipeline-warn\"}",
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqual(@as(usize, 1), result.warning_count);
    try std.testing.expectEqualStrings("claim_roles", result.diagnostics[0].field.?);
}

test "validateWorkflowFiles: dispatch without worker_tags is a warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "dispatch.json",
        .data =
        \\{
        \\  "id": "wf-dispatch",
        \\  "pipeline_id": "pipeline-dispatch",
        \\  "claim_roles": ["dev"],
        \\  "execution": "dispatch"
        \\}
        ,
    });

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try validateWorkflowFiles(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqual(@as(usize, 1), result.warning_count);
    try std.testing.expectEqualStrings("dispatch.worker_tags", result.diagnostics[0].field.?);
}

test "WorkflowWatcher: detects file changes" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var watcher = WorkflowWatcher.init(allocator, dir_path, &s);
    defer watcher.deinit();

    // Force last_check_ms to 0 so check runs immediately
    watcher.last_check_ms = 0;

    // Write a workflow file
    try std_compat.fs.Dir.wrap(tmp.dir).writeFile(.{
        .sub_path = "test_wf.json",
        .data =
        \\{"id":"wf-test","name":"Test WF","nodes":{}}
        ,
    });

    watcher.checkForChanges();

    // Verify workflow was inserted
    const wf = try s.getWorkflow(allocator, "wf-test");
    try std.testing.expect(wf != null);
    allocator.free(wf.?.id);
    allocator.free(wf.?.name);
    allocator.free(wf.?.definition_json);

    // Verify hash was stored
    try std.testing.expectEqual(@as(usize, 1), watcher.file_hashes.count());
}
