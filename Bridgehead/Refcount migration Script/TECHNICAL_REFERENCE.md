# QoreStor Refcount Migration Script — Ultra-Technical Function Reference

## Global setup & invariants

- `set -euo pipefail`
  - **e**: exit immediately on non-zero exit status (except in guarded contexts).
  - **u**: treat unset variables as an error.
  - **pipefail**: a pipeline fails if any command fails.
- `exec 3>&2`
  - **FD semantics**: Duplicates current stderr (FD 2) onto FD 3. All debug uses FD 3 so it bypasses later redirection in `setup_logging` and never pollutes command substitutions.
- **Key globals (selected)**
  - Mode flags: `DRY_RUN`, `SCAN_ONLY`, `VERIFY_CHECKSUM`, `TEST_MODE`, `DEBUG_MODE`.
  - Layout: `ALT_LAYOUT`, `REFCNT_SUBPATH`, `R3_JOURNAL_PATH`.
  - Paths: `CONFIG_FILE`, `BACKUP_DIR`, `LOG_DIR`, `LOG_FILE`, `MOUNTPOINT`, `NEW_LINE`.
  - Config toggles: `REFCNT_OLD`, `REFCNT_NEW`.
  - Accounting: `SCAN_FOUND`, `SCAN_TOTAL_BYTES`, `COPIED_FILES`, `SUMMARY[]`.
- **External commands used**: `system`, `systemctl`, `awk`, `sed`, `grep`, `numfmt` (optional), `tail`, `tr`, `tee`, `stdbuf`, `rsync`, `du`, `df`, `mountpoint`, `find`, `mktemp`, `wc`, `cmp`, `diff`.
- **Invariants**
  - Path computation uses `REFCNT_SUBPATH` (either `.ocarina_hidden/refcnt` or `refcnt`).
  - All debug prints go to FD 3 via `debug_*`, never contaminating stdout.
  - Config edits always via temp file; backup exists beforehand in live mode.
  - Services are stopped before live copy; started after config edit (and optional verify).

---

## Execution order (why this order)

1. `parse_args` → establish mode switches and capture free args.
2. `setup_logging` → tee stdout/stderr early so logs include everything.
3. `detect_layout_once` → set `ALT_LAYOUT`, `REFCNT_SUBPATH`, `R3_JOURNAL_PATH` so all subsequent FS ops are correct.
4. Mode branches:
   - **SCAN_ONLY**: `scan_refcnt_sizes` → `print_summary`.
   - **DRY_RUN**: `decide_dryrun_target` → prechecks → sim copy/verify → config preview → (optional) simulated start → `print_summary`.
   - **LIVE**: `setup_mountpoint` → `confirm_live_run` → `make_backup` → prechecks → stop → copy → (optional) verify → `apply_changes` → start → `print_summary`.
5. Any failure gates print summary and exit early to avoid partial state.

---

## Function-by-function (technical)

### `usage()`
**Purpose**: Print CLI usage and exit when requested.  
**Inputs**: none.  
**Outputs**: help to stdout.  
**Side effects**: none.  
**Deps**: none.  
**Errors**: n/a.  
**Complexity**: O(1).  
**Callers**: `parse_args` on `-h|--help` or unknown flag error.  
**Why here**: User-facing guidance at argument parse-time.

---

### `banner(text, color=$CYAN)`
**Purpose**: Emphasize log sections with ANSI colors.  
**Inputs**: `text`, optional `color`.  
**Outputs**: stdout.  
**Side effects**: none.  
**Complexity**: O(1).  
**Callers**: many.  
**Why**: Readability and log segmentation.

---

### `decide_dryrun_target()`
**Purpose**: In dry-run, determine if a *real* destination is available to simulate copying/verify more realistically.  
**Inputs**: `DRY_RUN`.  
**Outputs**: human prompts to stdout; debug to FD 3.  
**Side effects**: sets `DRY_HAS_TARGET`, `DRY_SKIP_SERVICES`, potentially calls `setup_mountpoint` to validate and form `NEW_LINE`.  
**Deps**: interactive TTY for `read`.  
**Errors**: none (logic switches).  
**Edge cases**: Non-tty invocation will block; intended for interactive testing.  
**Complexity**: O(1).  
**Callers**: `main` dry-run branch.  
**Why here**: Determines whether to simulate end-to-end (with a target) or plan-only (no target).

---

### `capture_system_info()`
**Purpose**: Print a stable subset of `system --show` for context.  
**Inputs**: external `system` tool.  
**Outputs**: stdout.  
**Side effects**: none.  
**Deps**: `system`, `grep`.  
**Errors**: if `system` missing, warning and return 0.  
**Complexity**: O(n) in lines of `system --show`.  
**Callers**: `setup_logging`.  
**Why**: Early in logs to anchor environment details.

---

### `detect_layout_once()`
**Purpose**: One-shot detection of standard vs. alternate layout by reading config state and path existence.  
**Inputs**: `CONFIG_FILE`.  
**Outputs**: debug to FD 3.  
**Side effects**: sets **globals** `ALT_LAYOUT`, `REFCNT_SUBPATH`, `R3_JOURNAL_PATH`.  
**Deps**: `grep`, `awk`, `sed`.  
**Errors**: tolerant (uses `|| true`), returns 0 always.  
**Edge**: If config says alt but path missing, remains standard.  
**Complexity**: O(n) lines of config.  
**Callers**: `main` early.  
**Why**: Downstream FS functions depend on correct layout.

---

### `detect_alt_repo_from_config()`
**Purpose**: Pure helper to print `R3_DISK_JOURNAL_PATH` when alt criteria satisfied.  
**Inputs**: `CONFIG_FILE`.  
**Outputs**: prints path on success; exit 0/1.  
**Side effects**: none.  
**Deps**: `awk`.  
**Edge**: Handles CRLF, quotes, export/no-export, `${...}` vs `$...`.  
**Complexity**: O(n) lines.  
**Callers**: helper retained.  
**Why**: Diagnostic or optional split of concerns.

---

### `get_repo_location()`
**Purpose**: Emit the repository root dir according to layout.  
**Inputs**: `ALT_LAYOUT`, `R3_JOURNAL_PATH`, external `system`.  
**Outputs**: repo path on stdout; errors on stderr.  
**Side effects**: none (debug FD 3).  
**Deps**: `system`, `awk`, `sed`.  
**Errors**: returns 1 if tool missing or path invalid.  
**Edge**: trailing spaces trimmed; ensures directory exists.  
**Complexity**: O(n) lines of `system --show`.  
**Callers**: `scan_refcnt_sizes`, `plan_copy_totals`, `copy_all_refcnt`, `verify_all_refcnt`.  
**Why**: Single source of truth for repo root.

---

### `to_bytes(s)` / `human_bytes(b)`
**Purpose**: Bidirectional size conversions with robust fallbacks.  
**Inputs**: `to_bytes` accepts “123”, “123,456 bytes”, or IEC suffix. `human_bytes` prints IEC.  
**Outputs**: stdout integer / formatted string.  
**Deps**: optional `numfmt`, otherwise `awk`.  
**Errors**: tolerant → defaults to stripped digits or 0.  
**Complexity**: O(1).  
**Callers**: scanning/printing.  
**Why**: Consistent size reporting independent of platform numfmt availability.

---

### `run_with_bar "$cmd" ...`
**Purpose**: Execute rsync (or similar) with a live progress bar (LIVE) or a simulated bar (DRY).  
**Inputs**: command vector. Detects `-n/--dry-run`.  
**Outputs**: progress bar on stdout; underlying command’s non-% lines reprinted; returns underlying exit code.  
**Side effects**: spawns background tail/reader; temporary file; relaxes `errexit`/`pipefail` internally and restores.  
**Deps**: `mktemp`, `stdbuf`, `tail --pid`, `tr`, `grep`.  
**Edge**: If underlying command doesn’t print `%`, bar won’t advance (expects rsync `--info=progress2`).  
**Complexity**: O(output lines).  
**Callers**: `copy_one_refcnt` (LIVE), `copy_all_refcnt` (LIVE).  
**Why**: User feedback for long transfers without contaminating stdout capture.

---

### `simulate_bar()`
**Purpose**: Background simulated progress for dry-run UX.  
**Inputs**: none.  
**Outputs**: prints progress loop until killed by caller.  
**Side effects**: infinite loop; caller must `kill`/`wait`.  
**Callers**: DRY-RUN branches in `copy_*`.  
**Why**: Perceived responsiveness during stat scans.

---

### `debug_log`, `debug_printf`
**Purpose**: Print debug messages **to FD 3** (original stderr).  
**Inputs**: `DEBUG_MODE`.  
**Outputs**: FD 3 only.  
**Why**: Never pollute stdout captured via `$(...)` given later tee redirection.  
**Callers**: many.

---

### `parse_args "$@"`
**Purpose**: Normalize flags into global booleans; collect free args → `PARSED_ARGS`.  
**Inputs**: CLI.  
**Outputs**: globals mutated.  
**Errors**: unknown `-*)` prints error and exits 2. `--help` exits 0.  
**Edge**: supports `--` to end options.  
**Callers**: `main`.

---

### `setup_mountpoint()`
**Purpose**: Prompt/validate `MOUNTPOINT` (path format + existence/mount checks by mode); compute `NEW_LINE="export TGTSSDDIR=$MOUNTPOINT/ssd/"`; create `.../ssd` live only.  
**Inputs**: `PARSED_ARGS`, `DRY_RUN`, `TEST_MODE`, `SCAN_ONLY`.  
**Outputs**: to stdout; updates `SUMMARY`.  
**Side effects**: sets `MOUNTPOINT`, `NEW_LINE`; may `mkdir -p` live.  
**Deps**: `mountpoint`.  
**Errors**: loop until valid; prints color errors.  
**Complexity**: O(1) prompt loop.  
**Callers**: `decide_dryrun_target` (dry-run only if target), `main` (LIVE).  
**Why**: Derive config edit line and target base; ensures safety constraints per mode.

---

### `setup_logging()`
**Purpose**: Split stdout/stderr to the same logfile via separate `tee` processes; leave FD 3 untouched. Print run headers and system info.  
**Inputs**: `TIMESTAMP`, `LOG_DIR`.  
**Outputs**: log file + banners.  
**Side effects**: redirects FD 1/2 process-wide.  
**Deps**: `mkdir`, `tee`, `stdbuf`.  
**Edge**: Using `-o0 -e0` for unbuffered tee improves progress smoothness.  
**Callers**: `main`.  
**Why**: Capture complete run artifacts without contaminating stdout-only captures.

---

### `get_system_state()`, `get_system_reason()`
**Purpose**: Small extractors over `system --show`.  
**Outputs**: strings; if missing, blank.  
**Deps**: `system`, `awk`, `sed`.  
**Callers**: service control.

---

### `verify_ready_to_stop()`
**Purpose**: Snapshot states prior to issuing a stop (or dry-run narrative).  
**Outputs**: banners + info; `SUMMARY` entries.  
**Deps**: `systemctl`, `system`.  
**Errors**: none (informational).  
**Callers**: all modes.  
**Why**: Visibility/gating before disruptive operations.

---

### `wait_for_service_stop(service="ocards")`
**Purpose**: Issue `systemctl stop`, then polling loop of `get_system_state` until “Stopped” or timeout.  
**Outputs**: live-overwritten status lines; `SUMMARY`.  
**Side effects**: stops service (LIVE).  
**Errors**: returns 1 on failed stop or timeout.  
**Callers**: dry-run (narrative only) and live.  
**Why**: Ensure FS quiet before copy ensures consistency.

---

### `start_services()`
**Purpose**: `systemctl start`, then loop until `System State=Operational Mode`, `Reason="Filesystem is fully operational for I/O."`, and `systemctl is-active == active` OR timeout.  
**Outputs**: live-overwritten status lines; `SUMMARY`.  
**Errors**: returns 1 on timeout/failure.  
**Callers**: dry-run (simulated) and live.  
**Why**: Ensure system returns healthy post-migration.

---

### `plan_copy_totals()`
**Purpose**: Count total files to consider under `<repo>/<id>/$REFCNT_SUBPATH` using `find -type f`.  
**Inputs**: repo from `get_repo_location`; `REFCNT_SUBPATH`.  
**Outputs**: integer to stdout.  
**Errors**: returns 1 if repo resolution fails.  
**Complexity**: O(number of files).  
**Callers**: copy planning, previews.  
**Why**: Preflight expectations for copy/verify.

---

### `safe_rsync ...`
**Purpose**: Guard-rail — if `DRY_RUN=true`, enforce presence of `-n/--dry-run` in args; otherwise delegate to `rsync`.  
**Outputs**: passthrough.  
**Errors**: returns `99` if policy violated.  
**Callers**: all rsync-invocations that must respect dry-run.  
**Why**: Prevent accidental writes during dry-run regressions.

---

### `scan_refcnt_sizes()`
**Purpose**: Per-`<id>` `du -sb` accumulation on `$REFCNT_SUBPATH`; prints per-dir human sizes + total.  
**Inputs**: repo, `REFCNT_SUBPATH`.  
**Outputs**: human-readable; updates `SUMMARY`, sets `SCAN_FOUND`, `SCAN_TOTAL_BYTES`.  
**Errors**: continues on missing refdirs; returns 0 even if 0 found (with message).  
**Complexity**: O(number of dirs/files).  
**Callers**: scan-only, live preview, dry-run contexts.  
**Why**: Size planning & visibility.

---

### `check_free_space(target_base, need_bytes)`
**Purpose**: Ensure `df -PB1` available space ≥ needed bytes; creates target dir (LIVE).  
**Outputs**: prints free/required; error on insufficient.  
**Errors**: return 1 if insufficient; 0 if unknown (`df` missing).  
**Callers**: `copy_all_refcnt` (LIVE and dry-run with target).  
**Why**: Avoid mid-transfer ENOSPC.

---

### `rsync_base_flags()` / `rsync_verify_flags()`
**Purpose**: Emit canonical rsync flags via printed lines (consumed into arrays).  
**Base**: `-aHAX --numeric-ids --sparse -W --human-readable --dirs`.  
**Verify**: base plus `--checksum` iff `VERIFY_CHECKSUM=true`.  
**Outputs**: list to stdout.  
**Callers**: `copy_*`, `verify_*`.  
**Why**: Centralize rsync policy.

---

### `copy_one_refcnt(SRC, DST, base)`
**Purpose**: Copy a **single** `refcnt` subtree (handles callers passing a repo `<id>` dir instead of explicit `.../refcnt`).  
**Inputs**: `REFCNT_SUBPATH`, `DRY_RUN`, `LOG_FILE`.  
**Normalization**: If `SRC` isn’t ending in `/refcnt` but `SRC/$REFCNT_SUBPATH` exists, rewrite `SRC`/`DST` to the subtree.  
**Dry-run**: `safe_rsync` with `-n --stats` into tmpfile; `simulate_bar`; parse “Number of regular files transferred” → report “would be transferred”.  
**Live**: run `run_with_bar rsync` with `--info=progress2`; print final stats.  
**Outputs**: human lines; `SUMMARY`; increments `COPIED_FILES`.  
**Errors**: live path returns rsync RC on failure; writes errors.  
**Complexity**: O(files under subtree).  
**Callers**: Not used by bulk path (bulk uses `copy_all_refcnt`), but correct independently.  
**Why**: Reusable primitive, safe normalization.

---

### `verify_one_refcnt(SRC, DST)`
**Purpose**: Rsync-based comparison (size/time or checksum).  
**Dry-run**: `-n --stats` to report would-compare counts.  
**Live**: Run rsync and interpret exit code + output: **no output** means identical; any output indicates deltas (treated as mismatch).  
**Outputs**: banners + `SUMMARY`.  
**Errors**: non-zero RC or non-empty output → failure.  
**Callers**: Not in main bulk flow; `verify_all_refcnt` preferred.  
**Why**: Reusable primitive.

---

### `copy_all_refcnt()`
**Purpose**: Bulk copy of all refcnt **files** across all `<id>` dirs.  
**Flow**:
1) `planned_files=$(plan_copy_totals)` → print/summary.  
2) `repo=$(get_repo_location)` guard.  
3) If dry-run without target → plan-only (no `df`, no rsync).  
4) Compute `target_base` from `NEW_LINE` (strip `export TGTSSDDIR=` and trailing `/`).  
5) `check_free_space` using `SCAN_TOTAL_BYTES`.  
6) Build `filelist` with `find . -type f -path "*/${REFCNT_SUBPATH}/*"` under repo root.  
7) DRY: `safe_rsync --files-from ... -n --stats` with simulated bar → print stats and totals.  
8) LIVE: `run_with_bar rsync --files-from ... --info=progress2` → “Rsync completed” + summary; set `COPIED_FILES`.
**Outputs**: detailed logs; `SUMMARY`.  
**Errors**: aborts on guards or rsync failure.  
**Complexity**: O(files).  
**Why**: Efficient bulk path; parent dirs created implicitly by file copies; `--dirs` retained.

---

### `verify_all_refcnt()`
**Purpose**: Bulk **per-`<id>`** verification of `SRC=$repo/<id>/$REFCNT_SUBPATH` vs `DST=$target_base/<id>/$REFCNT_SUBPATH`.  
**Flow**:
- DRY: `safe_rsync -n --stats $(rsync_verify_flags)` per dir → report “would be compared” and totals.  
- LIVE: ensure `DST` exists; run `safe_rsync --stats $(rsync_verify_flags)`; treat **non-empty output** or non-zero RC as mismatch/failure.
**Outputs**: per-dir results; totals; `SUMMARY`.  
**Errors**: fail fast on first mismatch; returns 1.  
**Complexity**: O(files).  
**Why**: Strong validation immediately after copy (optionally checksum).

---

### `config_preview_live()`
**Purpose**: For LIVE preview phase: show intended insert + refcnt toggle change (informational only).  
**Note**: The actual replace-or-insert logic is in `apply_changes` / `dry_run_preview`.  
**Outputs**: preview banners; `SUMMARY`.  
**Callers**: `confirm_live_run`.  
**Why**: Let operator confirm config impact before live run.

---

### `dry_run_preview()`
**Purpose**: Render a **temp transformed config** (using awk **replace-or-insert** logic) and show a colorized diff.  
**Logic (awk)**:
- Replace first `export TGTSSDDIR=...` with `$preview_line`, discarding any duplicates.  
- Else insert after `export TGTDIR`, else append at end.  
- Replace `PLATFORM_DS_REFCNTS_ON_SSD=0` with `=1`; ensure `=1` exists exactly once (no duplicates).
**Outputs**: `[DRY RUN]` preview and colored diff; `SUMMARY`.  
**Callers**: dry-run branch.  
**Why**: Safe visualization before live changes.

---

### `make_backup()`
**Purpose**: Create timestamped backup of `CONFIG_FILE` into `BACKUP_DIR`, preserving mode/owner (`cp -p`).  
**Outputs**: path; banners; `SUMMARY`.  
**Why**: Rollback safety.

---

### `apply_changes()`
**Purpose**: Apply **the same** awk transform as preview, but write to `${CONFIG_FILE}.tmp`, compare with `cmp`, and `mv` into place when different.  
**Diff**: show colorized diff vs `BACKUP_FILE`.  
**Dedupe**: ensures single `TGTSSDDIR` and single `PLATFORM_DS_REFCNTS_ON_SSD=1`.  
**Errors**: If no changes, print “already up-to-date”.  
**Why**: Deterministic, idempotent config update with audit.

---

### `print_summary()`
**Purpose**: Emit mode, checksum setting, dry-run target availability, and all accumulated `SUMMARY[]` lines; finish with log file path.  
**Outputs**: human-readable.  
**Why**: Single consolidated end-of-run artifact.

---

### `confirm_live_run()`
**Purpose**: Live **gating** step: show preview banners, scan totals, planned files, and config preview; require explicit `yes` to proceed.  
**Outputs**: interactive prompt; `SUMMARY`.  
**Why**: Human-in-the-loop confirmation reduces risk.

---

### `main "$@"`
**Purpose**: Orchestrator for all modes with strict failure gates and clear summaries.  
**Key guards**:
- Missing `CONFIG_FILE` after confirmation → abort.  
- Stop failure → abort.  
- Copy failure → abort before config.  
- Verify failure (when enabled) → abort before config.  
- Start failure → abort.
**Why**: Ensure **no partial migration** and clear operator feedback.

---

## Safety & correctness notes

- **FD discipline**: Debug to FD 3, logs split to FD 1/2 ensures `repo="$(get_repo_location)"` is clean even with logging active.  
- **Rsync enforcement**: `safe_rsync` prevents accidental writes during dry-run regressions.  
- **Deterministic config edit**: replace-or-insert logic guarantees **one** `TGTSSDDIR` and **one** `PLATFORM_DS_REFCNTS_ON_SSD=1`.  
- **Progress UX**: `run_with_bar` isolates fancy output from correctness (bar derived from `%` scan lines; summary reprinted sans `%`).  
- **Service gating**: stop before copy, verify, then config, then start — preserves consistency.

---

## Quick test checklist

- **Resolve repo**  
  `DEBUG_MODE=true repo="$(get_repo_location)" && printf '%s\n' "$repo"` → should print path only.
- **Scan-only**  
  `./script --scan-only` → per-dir lines + total; summary present.
- **Dry-run plan-only**  
  `./script --dry-run` (answer “no”) → plan-only copy/verify counts; config preview diff.
- **Dry-run with target**  
  `./script --dry-run /mnt/foo` (dir exists) → simulated copy/verify with counts; config preview with real line.
- **Live smoke (test mount, no service impact)**  
  `TEST_MODE=true ./script --verify /mnt/foo` → will still enforce confirmations; use test env.
- **Config transform dry-run**  
  Run `dry_run_preview` and confirm diff shows a single `TGTSSDDIR=...` and `PLATFORM_DS_REFCNTS_ON_SSD=1`.
