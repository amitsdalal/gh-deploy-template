# Magento in-place deploy template

For a **Magento 2 monolith deployed in place** on a server (no container image),
driven by a GitHub Actions **self-hosted runner** running as the app's unix user.

This is deliberately different from the image-based templates in this repo: Magento's
build (`setup:upgrade`, `di:compile`, `static-content:deploy`) mutates the deployed tree
and the database, so we pull + build **in place** rather than shipping a container.

## Flow

```
push to <deploy-branch>
      |
      v
self-hosted runner ON the server (running as the app user)
      |-- git pull the branch          (auth: ephemeral GITHUB_TOKEN, no stored creds)
      |-- composer install  IF composer.json/lock changed  (else skip)
      |-- maintenance:enable
      |-- setup:upgrade -> di:compile -> static-content:deploy -f
      |-- cache:flush -> indexer:reindex
      |-- maintenance:disable
      |-- restart php-fpm
```

On any failure a trap turns maintenance mode back off, so the store is never left down.

## Files

| File | Goes to |
| ---- | ------- |
| `backend-deploy.yml` | `.github/workflows/backend-deploy.yml` — fill the `<PLACEHOLDERS>`; commit to the **deploy branch AND the default branch** (the manual dispatch button only appears for workflows on the default branch) |
| `deployment.md` | hand to developers (Docker not required to understand it) |
| `redeploy.md` | how to re-run a deploy from the web |

## Server prereqs (one-time)

1. **Self-hosted runner as the app user** (see [`../shared/scripts/setup-runner.sh`](../shared/scripts/setup-runner.sh)),
   with labels matching `runs-on`. Prefer a **systemd** service so it survives reboots.
2. **Pin the app user's `php` CLI** to the Magento-supported version. If PHP is provided via
   SCL / multi-PHP, a `~/bin/php -> /usr/bin/phpXY` symlink is the robust way — it works for
   the **non-interactive runner**, which does *not* source `.bashrc`/`.bash_profile`, so a
   profile-only `scl enable` will NOT reach the runner.
3. **sudoers** NOPASSWD for EXACTLY the fpm restart:
   `appuser ALL=(root) NOPASSWD: /bin/systemctl restart <php-fpm-unit>`
4. **`composer auth.json`** on the box (Magento marketplace keys + any commercial-extension
   keys) for when `composer.lock` changes.

## Gotchas learned the hard way

- **Git auth:** a plain in-place `git pull` fails on the runner — the server has no stored
  credential and non-interactive git can't prompt. Use the workflow's ephemeral
  `GITHUB_TOKEN` via a **Basic** `http.extraheader` (`base64("x-access-token:TOKEN")`);
  git-over-HTTPS rejects `bearer`.
- **Pushing the workflow file** needs the `workflow` OAuth scope. If your token lacks it
  (403), push over **SSH** instead — SSH auth isn't subject to OAuth scopes.
- **Hardened hosts** (CSF + maldet/ClamAV) may quarantine the runner's `svc.sh` on
  extraction; the runner core still works, and `svc.sh install` usually succeeds on retry.
