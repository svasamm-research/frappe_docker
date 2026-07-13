# DMS deployment compose (Dokploy)

Source-of-truth for the Dokploy stacks that run the `dms-tenant` image.
Paste these into the Dokploy project's Compose editor (Environment values live
in Dokploy's Environment tab; the compose uses `${VAR}` placeholders and is
deployed with `--no-interpolate`).

- `dms-uat.yaml` — UAT bench (uat.videojet.svasamm.com)
- `dms.yaml` — production bench

## configurator note
The `configurator` service rebuilds only the apps that have esbuild bundles +
generate `assets.json` (`bench build --production --app frappe --app erpnext
--app india_compliance`). The CRM/Helpdesk Vue SPAs are pre-built in the image
and copied intact by the asset loop — rebuilding them here OOM-kills the deploy
container and blanks `/crm`.
