# gh-deploy-template

Deployment templates for shipping applications with **GitHub Actions + GHCR +
self-hosted runners**, using Docker Compose on the target server.

The shape is always the same:

```
push to a branch
      |
      v
GitHub Actions
      |-- build a container image
      |-- push it to GHCR (ephemeral GITHUB_TOKEN, no PAT)
      v
self-hosted runner ON the target server
      |-- pull the image
      |-- docker compose up -d
      |-- health check, roll back on failure
```

No SSH from GitHub to the server. No orchestration platform. One compose file
locally and on the server.

## Templates

| Template | For |
| -------- | --- |
| [`nextjs-template/`](nextjs-template/) | Next.js (pages router) served by PM2 behind an nginx sidecar |

More stacks get added as separate directories alongside it.

## Shared

Stack-agnostic pieces used by every template:

| Path | What it does |
| ---- | ------------ |
| [`shared/scripts/setup-runner.sh`](shared/scripts/setup-runner.sh) | Installs and registers a self-hosted runner on a RHEL-family server. Idempotent, one runner per environment, with an uninstall mode |
| [`shared/scripts/validate-env.sh`](shared/scripts/validate-env.sh) | Checks an env file for the defects that break deployments. Prints line numbers and key names only, never values |
| [`shared/docs/host-vhost.conf.example`](shared/docs/host-vhost.conf.example) | Host web-server vhost that terminates TLS and forwards to the container stack |

## How it is meant to be used

1. Copy the relevant template's files into the target repository.
2. Follow that template's `README.md`.
3. Give the developers `deployment.md` — it is written for people who do not
   know Docker.

## Why these choices

**GHCR with the workflow's `GITHUB_TOKEN`** rather than a personal access
token: nothing long-lived to rotate or leak.

**A self-hosted runner rather than SSH from CI**: the server needs no inbound
access, and the deployment runs where the containers live. It also gives one
stable outbound IP, which matters when an origin or database is IP-restricted.

**Docker Compose, not Kubernetes**: a single-server deployment does not need a
cluster, and the same file works on a laptop.

**Environment configuration lives in GitHub Environments**, never in the
repository, so the same commit can deploy to several environments and secrets
are not in git history.
