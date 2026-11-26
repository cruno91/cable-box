# ADR-0001: Control plane on the homelab Kubernetes "prod" cluster

**Status:** accepted, 2026-11-25

## Context

The CRT Raspberry Pi 5 has 4 GB of RAM and already runs FS42, MPV and the display stack. The homelab runs Argo CD-managed clusters with Gateway API and Traefik, cert-manager (LAN-only, split-horizon DNS) and SOPS secrets. A `prod` cluster will host this project.

## Decision

- The manager (API, UI) and PostgreSQL run on the `prod` cluster. They ship as Kustomize manifests referenced from `homelab-gitops`, exposed only through an HTTPRoute on the cluster Gateway. Secrets are SOPS-encrypted in `homelab-gitops`, never in this repo.
- The worker runs natively on the CRT Pi under systemd. The Pi isn't a cluster member, so playback doesn't depend on Kubernetes. The worker pulls jobs over HTTPS with a device credential, and the Pi accepts no inbound connections.
- Docker Compose is for local development only.
- Images are multi-arch (`linux/amd64`, `linux/arm64`).

## Consequences

- Manager outages don't affect playback.
- Postgres runs as a StatefulSet, or a CNPG `Cluster` once CNPG is available. Migrations run as an Argo PreSync Job.
- Deployment artifacts are `deploy/k8s/` and `deploy/systemd/`.
