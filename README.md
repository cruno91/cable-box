# cablebox

A control plane for [FieldStation42](https://github.com/shane-mason/FieldStation42) (FS42). It turns plain-language requests into persistent, editable TV channels built from a Plex-indexed NAS library, played by FS42 on a Raspberry Pi 5 driving a CRT over HDMI.

Plex supplies the metadata, the NAS supplies the media, and FS42 does the scheduling and playback. An LLM only drafts channel definitions. Nothing goes live without a reviewed preview and explicit approval.

Status: early development. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Guardrails

- Never modify original media (rename, move, delete, copy or transcode). The Pi mounts the NAS read-only.
- Never change the Pi's CRT, HDMI/EDID, X/LightDM or MPV display settings without the operator's approval.
- Never modify upstream FS42, and never write to its SQLite database directly. Use its CLI and config files.
- LLM output is validated structured data resolved against the catalog. It never contains commands, paths or native configs.
- LAN only: nothing is exposed to the internet.

## Repository layout

| Path | Contents |
|---|---|
| `internal/pathmap/` | Plex path → Pi mount path translation |
| `internal/fs42/probe/` | Read-only FS42 verifier, run inside FS42's Python environment |
| `test/integration/fs42/` | Pinned arm64 FS42 sandbox image, synthetic NAS generator, integration harnesses |
| `docs/` | Architecture, FS42 integration rules, roadmap, development, ADRs |

## Quick start

You need Go 1.27+, Docker with linux/arm64 support, and `make`.

```sh
go test ./...   # unit tests
make wp0        # FS42 sandbox suites
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, data model, channel definitions, link layout, activation flow, API |
| [docs/fs42-integration.md](docs/fs42-integration.md) | Rules for code that drives FS42 |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | Upstream pin, where each rule comes from in upstream, open hardware items |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Work packages, gates, acceptance criteria, operator prerequisites |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Setup, sandbox, CI, conventions |
| [docs/adr/](docs/adr/) | Architecture decision records |

## License

[MIT](LICENSE). FieldStation42 (MPL-2.0) isn't vendored; the sandbox fetches the pinned commit at build time.
