# FS42 integration rules

These rules apply to any code that drives FieldStation42, mainly `internal/fs42` and `cmd/pi-worker`. They hold for the pinned commit. When the pin changes, re-check each one against the source listed in [VERIFICATION.md](VERIFICATION.md#upstream-behavior-verified-at-the-pin).

## Workspaces

FS42 resolves all paths relative to the working directory, including its own JSON schema. A workspace is laid out like this:

```text
confs/main_config.json           # {"db_path": "runtime/fs42_fluid.db", ...}
confs/<station>.json
runtime/                         # DB, sockets, player_state.json, standby/brb images
fs42 -> <pinned checkout>/fs42   # required for schema validation
```

- Run every command from the workspace: `<checkout>/env/bin/python <checkout>/station_42.py ...`
- A candidate build never shares a DB, sockets or confs with the live install.

## CLI

| Rule | Reason |
|---|---|
| Pass exactly one allowlisted station name to `--rebuild_catalog`, `--add_day`, `--add_week`, `--add_month`, `--delete_schedules` | With no name, the command applies to every station |
| Never run `station_42.py` with no arguments | That starts the web server |
| Use an explicit argv, with no shell, a fixed executable and cwd, and a timeout | |
| Run builds as one fresh process per step, not through the HTTP API | API job state lives in process memory |
| Pass `--skip_chapter_scan` unless chapter-aware breaks are needed | Chapter scans are expensive |

A step succeeds only if **all** of these hold:
1. the exit code is 0 (FS42 also returns 0 on failure);
2. the output doesn't contain `I had failures:`;
3. the probe confirms the expected state.

## Station configs

- Use `"network_type": "standard"` with an absolute, per-revision `content_dir`.
- Always set `bump_dir` to a directory that contains media, even when `commercial_free` is set. Without it, scheduling fails.
- FS42 skips invalid configs at load time without failing. Before every build, the probe's `stations` output must show:
  - `schema_found: true`
  - every config `valid`
  - `skipped` empty
  - the expected stations loaded
- Channel numbers and network names are unique across all configs, managed or not.

## Media links

- Use symlinks to individual files only. Never link a directory: FS42 follows it recursively.
- Give each link a lowercase extension, one of `mp4 mpg mpeg avi mov mkv ts m4v webm wmv`. The target's own extension can be any case.
- Keep tag directories flat, because FS42 parses subfolder names as schedule hints.
- Preflight every target before a catalog build:
  - A dangling link aborts the whole station's catalog build.
  - Corrupt or zero-duration files are skipped silently, so compare catalog counts to link counts.
  - A missing tag directory yields zero clips, then fails at schedule time.
- `--rebuild_catalog NAME` deletes that station's schedule. Extend the horizon afterwards.

## Schedules

- Appends accept only `day`, `week` or `month`. `--add_week` stops at the next Monday's operating-hours start, not at +7 days.
- A new schedule starts at local midnight today. Appends continue from the current end without touching existing blocks.
- To reach a horizon, repeat `--add_day NAME` until the probe's `extents.end ≥ now + horizon`, with an iteration limit.
- `--delete_schedules NAME` deletes without regenerating.
- `liquid_blocks` timestamps are text in `isoformat(sep=" ")` form. Query with the same form.

## Player state

The selected channel is stored in `runtime/player_state.json` as `{"channel_index": N}`, an index into stations sorted by `channel_number`. A `start_channel` set in `main_config.json` takes precedence.

While FS42 is stopped, the worker:
1. maps the old index to a channel number using the old lineup;
2. maps that number to its index in the new lineup;
3. writes the file atomically.

## Probe

Run `internal/fs42/probe/fs42probe.py` with the pinned venv's Python, `FS42_HOME=<checkout>` and `cwd=<workspace>`. It opens the DB read-only and prints one JSON document.

| Command | Output |
|---|---|
| `stations` | Loaded and skipped stations; schema validation of every config |
| `catalog NAME` | Entries: tag, link path, realpath, duration, content type |
| `extents NAME` | First block start, last block end, block count |
| `schedule NAME [--start --end]` | Decoded blocks and plan entries |
| `coverage NAME --start --end` | Gaps, plan shortfalls, missing plan paths, decode errors, `ok` |
| `playpoint NAME --at T...` | Plan entry and offset a viewer joins at T |

## Activation and backups

- Back up with `sqlite3 "file:<db>?mode=ro" ".backup '<dst>'"`, then run `PRAGMA integrity_check`. Never copy a live DB file.
- Stop every FS42 writer before promoting or restoring. Replace the DB by same-filesystem copy plus `rename`, then delete `-wal`/`-shm`.
