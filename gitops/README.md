# gitops/

Templates for server-side environment files and generated compose files.

## What lives here (committed — safe, no secrets)

| File | Purpose |
|------|---------|
| `mariadb.env.example` | MariaDB env template |
| `cafirm.env.example`  | cafirm bench env template |

## What lives on the server at `~/gitops/` (NOT committed — has real passwords)

```
~/gitops/
├── mariadb.env       ← copy of mariadb.env.example with real DB_PASSWORD
├── cafirm.env        ← copy of cafirm.env.example with real values
└── cafirm.yaml       ← generated compose file (see below)
```

## Generating a bench compose file

Run on your **local machine** (not the server) from the `frappe_docker` root:

```bash
docker compose \
  --env-file gitops/cafirm.env.example \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.dokploy.yaml \
  -f overrides/compose.dokploy-ssl.yaml \
  config > /tmp/cafirm.yaml

# scp to server
scp /tmp/cafirm.yaml root@<hetzner-ip>:~/gitops/cafirm.yaml
```

Then in Dokploy: create a Docker Compose application and paste `cafirm.yaml`, or point it to the file path on the server.

## Adding a new client site to the cafirm bench

1. Add the new domain to `SITES_RULE` in `~/gitops/cafirm.env` on the server
2. Regenerate `cafirm.yaml` (run the docker compose config command above)
3. In Dokploy, redeploy the cafirm application
4. `bench new-site` + `bench install-app` for the new site (see site-operations)
