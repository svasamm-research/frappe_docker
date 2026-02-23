# gitops/

Templates for server-side environment files and generated compose files.

## Architecture

```
Manager VPS (CX11)                  Agent VPS (CX32)
──────────────────                  ────────────────────────────────
Dokploy dashboard :3000             MariaDB  (compose.mariadb-shared.yaml)
Traefik :80/:443 ──────────────────▶cafirm bench (cafirm.yaml)
Public IP ← all DNS                 Private IP: 10.0.0.2
                                    No public HTTP/S port needed
                         Scale: add Agent VPS → register in Dokploy → deploy new bench
```

## Files in this directory (safe to commit — no real secrets)

| File | Purpose |
|------|---------|
| `mariadb.env.example` | Template for MariaDB env vars |
| `cafirm.env.example`  | Template for cafirm bench env vars |

## Files that live on the server at `~/gitops/` (never commit — real passwords)

```
~/gitops/
├── mariadb.env     ← copy of mariadb.env.example with real DB_PASSWORD
├── cafirm.env      ← copy of cafirm.env.example with real values
└── cafirm.yaml     ← generated compose file (see below)
```

---

## Generating a bench compose file

Run on your **local machine** from the `frappe_docker` repo root.
This resolves all env variables into a single static compose file.

```bash
# Fill in real values locally (never commit this file)
cp gitops/cafirm.env.example /tmp/cafirm.env
# edit /tmp/cafirm.env — set DB_PASSWORD, SITES_RULE, CUSTOM_TAG

docker compose \
  --env-file /tmp/cafirm.env \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.dokploy.yaml \
  -f overrides/compose.dokploy-ssl.yaml \
  config > /tmp/cafirm.yaml

# Upload to server
scp /tmp/cafirm.yaml root@<agent-ip>:~/gitops/cafirm.yaml

# Clean up local temp files
rm /tmp/cafirm.env /tmp/cafirm.yaml
```

Then in **Dokploy UI → New Application → Docker Compose**:
- Target server: Agent VPS
- Paste contents of `cafirm.yaml`
- Deploy

---

## Adding a new client site to an existing bench

1. Update `SITES_RULE` in `~/gitops/cafirm.env` on the server to add the new domain
2. Regenerate `cafirm.yaml` (run the `docker compose config` command above)
3. In Dokploy → redeploy cafirm application (Traefik picks up new routing rule)
4. Create the Frappe site (run in backend container via Dokploy terminal):

```bash
bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password <DB_PASSWORD> \
  --admin-password <ADMIN_PASS> \
  --install-app erpnext --install-app hrms \
  --install-app india_compliance --install-app cafirm_override \
  newclient.yourdomain.com
```

---

## Scaling: adding a new Agent VPS

1. Provision a new Hetzner CX32 (attach to `svasamm-net` private network)
2. Run `scripts/setup-agent.sh` on it
3. Dokploy Manager → Servers → Add Server → enter new agent's SSH details
4. Deploy new benches targeting the new agent from Dokploy UI
