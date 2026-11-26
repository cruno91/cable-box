# Roadmap

| WP | Scope | Status |
|---|---|---|
| WP0 | Upstream integration: pin, sandbox, shared-symlink PoC, activation/rollback method | Done in the sandbox. Pi items open ([VERIFICATION.md](VERIFICATION.md#open-items-require-the-pi)) |
| WP1 | Catalog and path mapping: Plex adapter, catalog, migrations, fixture Plex server, sync job | In progress (`internal/pathmap` done) |
| WP2 | Channel schema, resolver, LLM drafting with a fixture provider | Not started |
| WP3 | Compiler and Pi worker: manifest, links, FS42 adapter, preview build, journaled activation and rollback | Not started |
| WP4 | Control-plane API and jobs: HTTP API, OpenAPI, durable jobs, device auth, worker protocol | Not started |
| WP5 | UI: setup, sync, search, prompt and editor, review, schedule preview, approval, jobs, health, rollback | Not started |
| WP6 | Operations: k8s manifests, worker systemd unit, install, backup and recovery, Pi acceptance on real media | Not started |

## Gates

- **WP0:** two-channel fixture passes against the pinned FS42; activation and rollback preserve unmanaged stations.
- **WP1:**
  - A paginated fixture covering duplicate IDs across servers, missing parents or GUIDs, multiple versions, multipart items, an incomplete scan and transient errors imports correct counts with no accidental removals.
  - A complete scan marks missing items unavailable and keeps history.
  - Version selection is deterministic.
  - No credentials appear in logs or fixtures.
- **WP2:**
  - Golden prompts pass: retro sci-fi, comedy overlap, movie-only, weekday/weekend split, title ambiguity, unavailable title, contradictory constraints, empty pool, malformed JSON, prompt injection.
  - The same definition and snapshot give the same membership and digest.
  - Gaps, overlaps, duplicate numbers, invalid IDs and unsupported strict rules are rejected.
  - The manual flow works with the LLM down.
- **WP3:**
  - Integration tests run against the pinned FS42.
  - Failure injection at every activation step ends in a correct rollback.
  - The journal reconciles after a crash.
  - Concurrent deploys are rejected.
  - A lower-number channel insert keeps the viewer's selection.
  - Invalid mounts or paths fail closed.
- **WP4:**
  - API contract and auth tests pass.
  - Competing deploys, unknown worker state after a timeout, manager restart and idempotent replay are handled.
  - Stale approvals are rejected.
  - A revision becomes active only after the device confirms.
- **WP5:**
  - A browser end-to-end flow (fixture provider) runs prompt → preview → approval → activation.
  - Stale UI state can't trigger a deploy.
  - A missing NAS and a degraded worker are shown distinctly.
  - The UI is accessible, and destructive actions need confirmation.
- **WP6:**
  - Real files play and seek correctly on the CRT, with geometry unchanged.
  - Playback survives Plex, LLM and manager outages.
  - A NAS outage fails safely and recovers.
  - Reboot, NTP, timezone and DST are checked.
  - One MPV pipeline runs regardless of channel count.

## Acceptance criteria

| ID | Test | Required result |
|---|---|---|
| A01 | Same file in two stations | Same canonical target, independent catalog entries, no duplicated bytes |
| A02 | Inconsistent NAS hierarchy | Metadata-driven selection; no filename parsing for identity |
| A03 | Multiple versions / multipart | Deterministic single-part version; multipart reported as unsupported |
| A04 | Prompt asks for missing content | No invented titles; a warning or clarification instead |
| A05 | Empty or unschedulable pool | Deployment blocked, with the reason |
| A06 | Schedule coverage | Now through the horizon covered by valid blocks; no unexplained gaps |
| A07 | Channel change | Joins the right item and offset; inactive channels aren't decoding |
| A08 | Plex / LLM / manager offline | Playback continues while the NAS is present |
| A09 | Missing NAS or malformed path | Preflight rejects without touching active state or the NAS |
| A10 | Concurrent or stale approval | One writer per device; conflict reported |
| A11 | Build or restart fails | Prior lineup restored and verified; error surfaced |
| A12 | Reboot mid-deployment | Deterministic reconcile or rollback |
| A13 | Add or edit a station | Valid config, catalog and schedule after a controlled restart |
| A14 | Other stations and the display | Unmanaged configs, schedules and CRT settings unchanged |
| A15 | Schedule extension | No interruption to current playback; no destructive reset |
| A16 | Unsupported strict rule | Explicit warning or rejection |
| A17 | Scale | Sync, link count, build time and Pi resource use recorded; no video-sized local storage growth |
| A18 | Security | Auth, path containment, no shell interpolation, no token leakage, no WAN exposure |

## Operator prerequisites

Needed before the first real deployment:

- Filler/bumper clips. Every channel needs them, and none are fetched automatically.
- Plex URL, a read-only token, and the library sections to use.
- NAS share and protocol (NFS/SMB), and the read-only mount paths on the Pi.
- Read-only Pi access to record:
  - the installed FS42 commit and path;
  - systemd units and `main_config.json`;
  - where the CRT profile backup is.
- Channel number range, timezone (must match the Pi), and a maintenance window for activation restarts.
- Allowed LLM provider, and what metadata may be sent to it.

## Out of scope for the MVP

- Seamless live lineup switching or cross-process config reload.
- Multiple viewers or playback devices.
- IPTV.
- An external scheduler.
- An advanced rule solver.
- Embeddings.
- Plex streaming or transcode fallback.
- Branding, or any image, audio or video generation.
- Fetching filler automatically.
