# Deployment Guide

How this app gets from your laptop to a live server. Written to be readable
without prior Docker or CI knowledge.

No server addresses, ports or credentials appear in this document on purpose.
Everything environment-specific lives in **GitHub Environments** (Settings →
Environments), so this file stays safe to share and never goes stale.

---

## 1. The short version

You push to a branch. GitHub builds the app into a container image, stores it,
and a small agent already running on the target server pulls that image and
restarts the site. Nobody logs into a server. There is nothing to run by hand.

```
you push  ──►  GitHub Actions
                  │
                  ├─ 1. build a container image from your code
                  ├─ 2. upload it to GitHub's image registry (GHCR)
                  │
                  └─ 3. the runner ON the server pulls that image,
                        restarts the containers, health-checks the site,
                        and rolls back automatically if it fails
```

Watch it happen in the repository's **Actions** tab.

---

## 2. Which branch goes where

| You push to | It deploys to |
| ----------- | ------------- |
| `uat`       | the UAT site  |
| `main`      | the production site |

Nothing else deploys. Push a feature branch and no deployment happens — that is
intentional. To ship, merge into `uat` (or `main`).

This is enforced in two independent places, so a mistake cannot leak into
production:

1. **The workflow** maps the branch name to an environment, and fails loudly on
   any branch it does not recognise.
2. **GitHub Environments** only accept deployments from their allowed branch. So
   even a hand-edited workflow cannot push a feature branch to production.

---

## 3. The one thing that surprises everyone

**Config is frozen into the image when it is built, not when it starts.**

Next.js takes every variable whose name begins with `NEXT_PUBLIC_` and writes its
value *directly into the JavaScript that browsers download*, during the build.
This is not a choice we made; it is how Next.js works. Browsers cannot read
server environment variables, so the value has to be baked in.

Three practical consequences:

- **UAT and production are different images.** The same commit produces two
  different builds because the values differ. An image cannot be "promoted"
  from UAT to production.
- **Changing a value requires a rebuild.** Editing the environment variable and
  restarting the container does nothing — the old value is already inside the
  JavaScript. Re-run the deployment.
- **Anything named `NEXT_PUBLIC_*` is public.** It ships to every visitor's
  browser and anyone can read it in developer tools. Never put a private key,
  password, or server-side API secret behind that prefix.

Server-side code (`getServerSideProps`, API routes) *does* read variables at
runtime, so those behave the way you would expect.

> If we ever want one image to serve every environment, that requires a code
> change — moving client config to Next's `publicRuntimeConfig` or fetching it
> from an API route at startup. It is a refactor, not a settings tweak.

---

## 4. Where environment variables live

Nothing environment-specific lives in the repository. Every value is stored in
GitHub under **Settings → Environments**, and each environment holds its own
copy. That is what makes the same commit deployable to different places.

### The environments

| Environment | Deploys from branch | Purpose |
| ----------- | ------------------- | ------- |
| `uat`  | `uat`  | testing and client review |
| `prod` | `main` | the live site |

Each is locked to its branch on the GitHub side, so a deployment cannot reach
the wrong environment even if a workflow is edited.

### What each environment holds

| Name | Type | What it is for |
| ---- | ---- | -------------- |
| `DOTENV` | secret | the whole `.env` file for that environment, pasted as text |
| `PORT` | variable | the port the site is published on for that environment. Must differ between environments that share a machine, or the second deployment cannot start |
| `REPLICAS` | variable | how many copies of the app container to run |
| `API_HOST` | variable | the API hostname to resolve directly instead of through the CDN. Optional |
| `API_ORIGIN_IP` | variable | the address that hostname should resolve to during builds and at runtime. Optional |

`API_HOST` and `API_ORIGIN_IP` work as a pair: set both to switch the override
on, leave either blank and everything resolves normally. Section 5a explains
why this exists.

Values are intentionally not listed here. Read them in the GitHub UI, where
they belong, so this document cannot drift or leak.

### Adding or changing a value

1. Settings → Environments → pick the environment.
2. Edit the `DOTENV` secret, or the variable, as appropriate.
3. Re-run the deployment so a new image is built. **This step is not optional**
   for anything in `DOTENV` — see section 3.

### Rules for `.env` content

These are not style preferences. Each one below has broken a real deployment:

- **No spaces around the `=`.** Write `KEY=value`, never `KEY = value`. The
  application's own loader trims them, but Docker and the shell do not, so a
  file that builds fine will fail at deploy time.
- **Quotes must be balanced, or absent.** A value like `'production` with no
  closing quote is silently accepted by the app's loader and rejected outright
  by Docker, which refuses to read the entire file.
- **No stray spaces inside a value.** A key or URL with a trailing space fails
  authentication in tools that do not trim.
- **Unix line endings.** A file saved with Windows line endings puts an
  invisible character at the end of every value.
- Keep the variable names the code expects. A missing one does not raise an
  error; it quietly becomes `undefined` and breaks a feature at runtime.
- Never commit a `.env` file. It is git-ignored and must stay that way.

A quick way to check a file before pasting it in: every line should look like
`NAME=value`, with no spaces on either side of the `=` and no lone quote
characters.

---

## 5. What actually runs on the server

Three layers, outermost first:

1. **The server's web server** terminates HTTPS for the domain and forwards
   requests inward. Its config lives in `sites-enabled/` on the server.
2. **A small proxy container** sits in front of the app, handling caching rules
   for static files.
3. **The app container** runs the Next.js server under **PM2**, a process
   manager that keeps several copies running and restarts any that crash.

Each environment gets its own isolated set of containers, its own network, and
its own port, so multiple environments can share one machine safely.

---

## 5a. Reaching the API directly (why a hosts override exists)

The build ends by generating the sitemap, which asks the API for every product
URL. On the production catalogue one of those queries takes around four
minutes. Cloudflare gives up on any request that takes longer than about a
hundred seconds and returns a 524, so the build used to fail every time.

The fix is to let the build talk to the API server directly rather than through
Cloudflare, by mapping the API hostname to its origin address. Two details make
this less obvious than it sounds:

- **A container does not inherit the server's `/etc/hosts`.** Even on a machine
  where that mapping already exists, the build and the app run inside
  containers with their own hosts file and their own resolver. The mapping has
  to be given to them explicitly.
- **The running app needs it too, not just the build.** Server-rendered pages
  call the same API on every request, so the override is applied to the running
  container as well.

Set `API_HOST` and `API_ORIGIN_IP` on the environment to switch this on. Leave
either blank and everything resolves normally through Cloudflare, which is fine
for environments whose API answers quickly.

For local development, put the same two names in your `.env`; there is no
default, so a missing value fails immediately rather than quietly building
against Cloudflare and timing out.

This is a workaround, not a cure. It trades Cloudflare's protection on that one
path for a direct origin call, and it makes builds take roughly five minutes.
The real fix is on the API side: the slow query returns in about four minutes
while a sibling query of the same shape returns in under two seconds, which
points at the query rather than the volume of data.

## 6. Checking and troubleshooting a deployment

**Did it work?** Actions tab → the run for your commit. Three jobs must be
green: `setup`, `build`, `deploy`. The `deploy` job ends with a health check
that actually loads the site; if the site does not respond, the job fails.

**It failed — now what?**

| Symptom | Most likely cause |
| ------- | ----------------- |
| `build` fails installing packages | A malformed line in the `DOTENV` secret (often a space before `=`) |
| `build` fails pushing the image | Repository or org permissions on the image registry |
| `deploy` waits forever, never starts | The server's agent is offline, or its label does not match the environment |
| `deploy` fails pulling the image | The registry package is not linked to this repository |
| Health check fails | The app crashed on boot, or the environment's `PORT` clashes with something else |
| Build fails at the sitemap step with a 524 | The API took longer than Cloudflare allows -- set `API_HOST` and `API_ORIGIN_IP` (see 5a) |
| Site loads but a feature is broken | A variable is missing from `DOTENV` — remember it needs a rebuild |

The failing step prints the container logs, so read the job output before
touching the server.

**Rolling back.** The deploy job rolls back to the previous image automatically
if the health check fails. To roll back a *working but bad* release, re-run the
last good workflow run from the Actions tab. Every image is tagged with the run
number that produced it, so previous versions remain available.

---

## 7. Rules for developers

**Do**

- Merge into `uat` and verify there before going anywhere near `main`.
- Add new config through the environment's `DOTENV` secret, never in code.
- Assume every `NEXT_PUBLIC_*` value is visible to the public.
- Read the failing job's logs before asking for server access — the answer is
  almost always there.

**Do not**

- Commit a `.env`, a private key, a certificate, or a password.
- Edit files or configuration directly on the server. The next deployment
  overwrites app changes, and hand edits to the web server config can be
  reverted by the control panel that manages the domain.
- Put a secret behind the `NEXT_PUBLIC_` prefix.
- Push straight to `main` to "test something".

---

## 8. Running it locally

You need Docker Desktop and a `.env` file (ask for the UAT values).

```bash
docker compose up --build      # first run, or after changing dependencies
docker compose up -d           # start
docker compose logs -f web     # watch the app
docker compose down            # stop
```

The site is then served on the local port defined in `docker-compose.yml`. This
uses the same layering as the server, so behaviour matches production closely.

---

## 9. Known gaps

Honest list of things that should improve, so nobody is surprised:

- **No lock file is committed.** `package-lock.json` is currently git-ignored,
  so each build re-resolves dependency versions. Two builds of the same commit
  can therefore differ, and a third-party release can break a build with no code
  change. Committing the lock file is the single highest-value fix here.
- **A dependency conflict is worked around**, not resolved: one package requires
  an older version of another than the project uses, so installation runs in a
  relaxed mode. Worth cleaning up.
- **Environments share one machine**, so a heavy deployment in one can slow the
  other. They are separated by container boundaries, not by hardware.
- **Client configuration is build-time** (section 3). Fixing that is a code
  change and would let one image serve every environment.
