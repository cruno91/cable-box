# Development

## Requirements

- Go 1.27+
- Docker with linux/arm64 (native on Apple Silicon, emulated elsewhere)
- make, jq, sqlite3

Upstream FS42 runs only inside the sandbox container, never on the host.

## FS42 sandbox

`test/integration/fs42/Dockerfile` builds a linux/arm64 `debian:trixie-slim` image containing distro Python, ffmpeg, the pinned FS42, and dependencies from `requirements.lock`.

| Target | Does |
|---|---|
| `make fs42-image` | Build the sandbox image (`NO_BUILD=1` reuses an existing one) |
| `make fs42-lock` | Regenerate `requirements.lock` |
| `make fixtures` | Create the synthetic NAS volume `cablebox-fakenas` |
| `make wp0-upstream-tests` | Upstream pytest suite |
| `make wp0-poc` | Shared-symlink PoC and hazard cases |
| `make wp0-activation` | Activation and rollback |
| `make wp0` | All of the above |

The harnesses print `PASS`/`FAIL <id> <desc>` lines and exit with the failure count. Logs and probe JSON go to `.work/evidence/`.

The synthetic NAS (`gen_fixtures.sh`) is always mounted read-only. Never point the harnesses at real media.

### Changing the FS42 pin

1. Update `FS42_SHA` in the `Makefile` and the `Dockerfile` (CI checks they match).
2. Run `make fs42-lock`.
3. Run `make wp0` and re-check each rule against the source listed in [VERIFICATION.md](VERIFICATION.md).
4. Never update the FS42 installed on the Pi as part of this.

## CI

`.github/workflows/ci.yml`: Go, fuzz and lint jobs run in parallel. The arm64 sandbox job runs `make wp0` after they pass and uploads `.work/evidence/` as the `wp0-evidence` artifact.

- For a private repo, set the `FS42_SANDBOX_RUNNER` repository variable to an arm64 runner label. Never use the CRT Pi.
- Dependabot updates actions and Go modules. It doesn't touch the FS42 pin or `requirements.lock`.
- The docs link check is case-sensitive. macOS won't catch wrong-case links locally.

## Conventions

- Go module `github.com/cruno91/cablebox`. Code goes in `internal/`, binaries in `cmd/`.
- Run `go vet ./...` and `go test -race ./...` before pushing.
- Write table-driven tests, and fuzz any parser of untrusted paths or input.
- Put a `context` deadline on every external call (Plex, LLM, subprocesses).
- Use structured logs, with secrets redacted.
- Use parameterized SQL only. Run subprocesses with an explicit argv and allowlisted arguments, never a shell.
- Keep external systems behind adapters: `internal/plex`, `internal/fs42`, `internal/llm`.
- Python is limited to `internal/fs42/probe/fs42probe.py`: read-only, a single file, JSON output, explicit station names.
- Commit no real library paths or titles, tokens, or operator hostnames. Fixtures are synthetic. Deployment secrets live SOPS-encrypted in the homelab GitOps repo.
- Record newly verified upstream behavior and open items in [VERIFICATION.md](VERIFICATION.md).
