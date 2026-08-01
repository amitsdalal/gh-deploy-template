# Redeploying without a rebuild

How to release again — or roll back — without waiting for a full build.

A normal deployment builds the application from source, which takes several
minutes. Most of the time you do not need that: the image already exists and
you only want it running again, or you want a previous one back.

No addresses, ports or credentials appear in this document. Everything
environment-specific lives in GitHub Environments.

---

## When to use which

| Situation | Use |
| --------- | --- |
| Release the current build again | **redeploy**, default inputs |
| Go back to a previous release | **redeploy**, set `version` |
| Containers are stuck or misbehaving | **redeploy**, tick `force_recreate` |
| Repeat one specific past deployment exactly | **re-run the deploy job** of that run |
| The code changed | a normal push — you need a build |

---

## Redeploy from the web interface

**Actions → redeploy → Run workflow**

Then, in the panel that appears:

1. **Choose the branch that matches the environment.** This is the step people
   get wrong — see the rule below.
2. Fill in the inputs.
3. Run workflow.

### Inputs

| Input | Meaning |
| ----- | ------- |
| `environment` | which environment to release to |
| `version` | which build to release. `latest` means the most recent one for that environment. Give a run number instead to go back to an older build — **this is how you roll back** |
| `force_recreate` | rebuild the containers from scratch instead of leaving running ones alone. Leave off normally; turn on when something is stuck |

### The one rule

**The branch you run it from must match the environment you are deploying to.**

Each environment only accepts deployments from its own branch. If they do not
match, the run is rejected in about a second with:

> Branch "…" is not allowed to deploy to … due to environment protection rules.

That is a deliberate safety guard, not a fault. It means the wrong branch's code
cannot reach an environment, even by hand. If you see that message, re-run it
with the branch that belongs to that environment.

---

## Redeploy from the command line

```bash
# release the latest build for an environment
gh workflow run redeploy.yml --ref <branch> -f environment=<env>

# roll back to an earlier build
gh workflow run redeploy.yml --ref <branch> -f environment=<env> -f version=<run-number>

# force a clean recreate of the containers
gh workflow run redeploy.yml --ref <branch> -f environment=<env> -f force_recreate=true
```

The same branch rule applies to `--ref`.

To find the run number of an earlier build, look at the Actions history: the
number beside a successful run is the tag its image was published under.

---

## Re-running the deploy job of a past run

There is a second option that needs no inputs at all: open any successful run,
hover the deploy job in the left sidebar and click the re-run icon. That repeats
exactly that deployment, reusing the image it built, and skips the build.

Use it when you want to repeat a specific past deployment. Use **redeploy** when
you want to choose the version, or force a recreate.

---

## What actually happens

Roughly twenty seconds, versus several minutes for a full build:

1. Pull the requested image from the registry.
2. Write that environment's configuration.
3. Start the containers.
4. Check the site actually responds, and fail the run if it does not.

Nothing is rebuilt and no source is compiled, so the result is byte-for-byte the
image that was tested before.

---

## When a redeploy will not help

**The configuration changed.** Anything the application reads at build time is
baked into the image, so releasing the same image again cannot pick it up. That
needs a new build — see `deployment.md`.

**The code changed.** Same reason; push and let it build.

**The site is down because the application is broken.** Redeploying the same
image reproduces the same fault. Roll back to an earlier `version` instead.
