# Verification

## Upstream pin

| | |
|---|---|
| Upstream | `shane-mason/FieldStation42` |
| SHA | `c313f7dd622991a7ef58b46fa7c24d6b11037270` |
| Python deps | `test/integration/fs42/requirements.lock` (upstream's `install/requirements.in` is unpinned) |
| Sandbox | linux/arm64 `debian:trixie-slim`, Python 3.13, ffmpeg 7.1, `python3-tk` (required by upstream tests) |
| Installed on the Pi | Not yet inspected |

`make wp0` (and CI) verifies the pin against the synthetic library.

## Upstream behavior verified at the pin

When changing the pin, re-read the upstream source listed for each rule. Check IDs refer to `run_poc.sh` (`poc:`) and `run_activation.sh` (`act:`).

| Behavior (rule in [fs42-integration.md](fs42-integration.md)) | Upstream source | Check |
|---|---|---|
| Appends accept only `day`/`week`/`month` | `fs42/liquid_schedule.py` `_extend` | |
| `add_week` ends at next Monday's operating-hours start; a new schedule starts at local midnight | `_extend`, `fs42/timings.py` `next_week` | poc:W00c, W00d |
| `bump_dir` with media is required, even when `commercial_free` | `fs42/catalog.py` `find_bump`, `make_reel_block` | poc with `BUMP_MODE=empty` |
| Exit 0 on failure; failures are printed as `I had failures:` | `station_42.py` `main`, `print_outcome` | poc:F01, F02 |
| No station names = all stations; no argv = web server | `station_42.py` `build_parser`, end of `main` | |
| No schema validation at load; invalid files skipped | `fs42/station_io.py` `load_and_process_all_stations`, `validate_station_config` | poc:S01–S03 |
| All paths cwd-relative | `fs42/station_manager.py`, `fs42/station_io.py` | poc:I01, I02 |
| Uppercase link extension not found | `fs42/media_processor.py` `_find_media` | poc:H01 |
| Corrupt target skipped | `process_one` | poc:H02 |
| Dangling link aborts catalog build | `rich_find_media` | poc:H03 |
| Directory symlinks followed recursively | `_rfind_media` | poc:H04 |
| Subfolder names parsed as hints | `_process_subs`, `fs42/schedule_hint.py` `FOLDER_HINT_KLASSES` | |
| Missing tag dir → 0 clips, fails at schedule | `fs42/catalog.py` `_scan_directory` | poc:H05 |
| `--rebuild_catalog` deletes the station's schedule | `station_42.py` `rebuild_catalogs` | act:A03 |
| ffprobe results cached by realpath; rebuilds still stat targets and read `.nfo` sidecars | `fs42/fluid_builder.py`, `fs42/fluid_statements.py` | |
| Selected channel stored as an index | `field_player.py` `load_channel_index` | act:P05 |
| Block timestamps stored as `isoformat(sep=" ")` text | `fs42/liquid_io.py` `get_liquid_block_at` | |
| Same file in two stations: separate catalog rows, concurrent airing allowed | `fs42/catalog_io.py` (unique `station, tag, path`) | poc:C03–C08, W04 |
| Stopped-snapshot promotion and rollback preserve unmanaged stations | n/a | act:A06, P04, B01–B04 |

## Open items (require the Pi)

- Installed FS42 SHA, install path, systemd units, and the `main_config.json` keys `schedule_agent`, `start_channel` and `api_key`. Inspect read-only.
- Live player: only one MPV instance runs regardless of channel count; mid-item joins land at the right offset; behavior when a reset or append happens during playback.
- How the API key is passed (`fs42/fs42_server/auth.py`); tuning via `GET /player/channels/{n}`.
- How the `LiveScheduleAgent` top-up interacts with the `--add_day` horizon loop.
- Sequence semantics, and features longer than their slot. WP2 rejects strict sequence and marathon rules until these are tested.
- Chapter-scan cost, NAS probe latency over NFS/SMB, Pi 5 decode and seek per codec, DST, and link count versus build time.
