# Next.js deployment template

Next.js (pages router) in a container, run by **PM2** in cluster mode, behind an
**nginx** sidecar, deployed by **GitHub Actions** to **GHCR** and released by a
**self-hosted runner** on the target server.

## Files

| File | Purpose | Edit per project? |
| ---- | ------- | ----------------- |
| `Dockerfile` | Builds the app image | Node version, timezone, port |
| `process.yml` | PM2 process definition | instance count |
| `pm2-next.js` | PM2 launcher — do not delete, see below | no |
| `nginx.conf` | Sidecar proxy in front of the app | rarely |
| `docker-compose.yml` | Local development stack | no |
| `docker-compose-prod.yaml` | Deployment stack, pulls from GHCR | no |
| `.dockerignore` | Build context trimming | rarely |
| `.env.example` | Template for the real `.env` | yes |
| `.github/workflows/build-deploy.yml` | The pipeline | branch names |
| `deployment.md` | Guide for the app developers | project wording |
| `redeploy.md` | How to redeploy or roll back without a rebuild | project wording |

## Setting up a new project

**1. Copy the files** into the repository root (including `.github/`).

**2. Create the branches** the workflow deploys from. It ships with `uat` ->
uat and `main` -> prod; edit the `on.push.branches` list and the `case` in the
`setup` job to change that. Anything unmapped fails loudly rather than silently
doing nothing.

**3. Create a GitHub Environment per target** (Settings -> Environments), and
lock each to its branch so a deployment cannot reach the wrong place:

| Name | Type | Purpose |
| ---- | ---- | ------- |
| `DOTENV` | secret | the whole `.env` for that environment |
| `PORT` | variable | host port to publish on. **Must differ** between environments sharing a machine |
| `REPLICAS` | variable | app container count |
| `APP_NAME` | variable | optional, defaults to the repository name |
| `API_HOST` | variable | optional, with `API_ORIGIN_IP` — see below |
| `API_ORIGIN_IP` | variable | optional |

**4. Set up a runner per environment** on the target server, labelled with the
environment name:

```bash
sudo ./setup-runner.sh --url https://github.com/OWNER/REPO --token <TOKEN> --label prod
```

**5. Point a domain at it** using `shared/docs/host-vhost.conf.example`.

**6. Turn off fork-PR workflows** (Settings -> Actions -> General). A runner in
the `docker` group is root-equivalent on that machine.

## Things that will bite you

**`NEXT_PUBLIC_*` is compiled in at build time.** Next writes those values
directly into the browser bundle, so an image is environment-specific — a UAT
image and a production image are different artifacts, and changing a value
needs a rebuild, not a restart. Never put a secret behind that prefix; it ships
to every visitor.

**`pm2-next.js` exists for a reason.** PM2 6.x appends the config file path to
the child process argv, and `next start` reads it as the project directory,
crash-looping the container with `No such directory exists as the project
root`. It happens with YAML and JS configs, string and array args alike. The
launcher rewrites argv so whatever PM2 appends is ignored.

**Do not `npm install -g npm@latest` in the image.** npm 12 disables
git-protocol dependencies, so any project with a `github:` dependency fails
with `EALLOWGIT` — and "latest" makes builds non-deterministic anyway. Use the
npm bundled with the pinned Node image.

**Containers do not inherit the host's `/etc/hosts`.** If the app must reach an
API directly rather than through a CDN — usually because a slow query exceeds
the CDN's request timeout — set `API_HOST` and `API_ORIGIN_IP`. The workflow
then applies the mapping to the build *and* to the running container, since
server-rendered pages call the API on every request. Fixing only the build is a
common half-measure.

**Env files are validated automatically.** The workflow checks the file the
moment it is written, in both the build and deploy jobs, and fails in about a
second with the line number and key name if anything is malformed. This exists
because a malformed value can build fine and only fail at deploy -- the app's
own loader is forgiving, Docker is strict. Values are never printed, so it is
safe in CI logs.

Check a file yourself before pasting it into a secret:

```bash
../shared/scripts/validate-env.sh .env
```

**Compose `deploy.replicas` only scales the app service.** The proxy has a
fixed container name and stays single.

**The proxy resolves the app at request time, via a variable and Docker's
embedded DNS.** Do not "simplify" it back to `proxy_pass http://web:3000;` --
nginx then resolves that name while parsing the config and exits if the app is
not up yet, crash-looping forever afterwards. The deploy also runs
`--force-recreate`, because the proxy's image never changes and `up -d` would
otherwise never recreate it, letting it keep a stale network reference it can
never recover from.

## Local development

```bash
cp .env.example .env     # then fill it in
docker compose up --build
docker compose logs -f web
docker compose down
```

The site is served on the port set by `PORT` in `.env`.
