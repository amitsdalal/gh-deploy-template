# Backend deployment

Deploys are automated with a GitHub Actions **self-hosted runner** on the server.
No SSH and no manual runbook — **push to the deploy branch and it deploys.**

## What a deploy does

On **push to the deploy branch** (and via manual dispatch — see *Redeploy*), the runner
deploys **in place** under the app root and:

1. `git pull` the branch (authenticated with the workflow's ephemeral token — no stored
   credentials on the box).
2. **`composer install` only if `composer.json` / `composer.lock` changed** in that push
   (or `vendor/` is missing). Pure code/config/template changes skip Composer — faster.
3. Magento build: `maintenance:enable → setup:upgrade → setup:di:compile →
   setup:static-content:deploy -f → cache:flush → indexer:reindex → maintenance:disable`.
4. Restart PHP-FPM.

If any step fails, **maintenance mode is turned back off automatically** so the store is
never left down.

## Deploy (normal)

Merge/push to the **deploy branch**. Follow it in the repo's **Actions** tab → **Backend deploy**.

> If your change adds or updates a Composer package, commit the updated **`composer.json`
> and `composer.lock` together** — the pipeline uses them to decide whether to run
> `composer install`. Forgetting the lockfile means the new dependency won't be installed.

## Redeploy (manual re-run from the web)

See [`redeploy.md`](./redeploy.md).

## Good to know

- A deploy briefly puts the store into **maintenance mode** during the build step.
- App-level failures (a bad migration, a broken module, missing config) surface in the
  **Actions** log at the failing `bin/magento` step — that's application territory, not the
  pipeline. The pipeline's job is to run your commands, in order, reproducibly.
- This document intentionally contains **no** server names, IPs, or credentials.
