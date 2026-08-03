# Redeploy (manual re-run from the web)

To re-run the deploy without a new commit — to retry a failed run, or reapply after a
manual change on the server:

1. Repo → **Actions** → **Backend deploy** (left sidebar).
2. **Run workflow** → **Use workflow from** = your deploy branch → **Run workflow**.
3. Optional: tick **`force_composer`** to force `composer install` even when the composer
   files are unchanged (e.g. after clearing `vendor/`).

It runs the exact same steps as an automatic deploy. Watch it in the **Actions** tab; a
failed `bin/magento` step is an application issue, not a pipeline issue.
