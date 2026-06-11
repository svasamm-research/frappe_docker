# gitops/

Templates for server-side environment files and generated compose files.

## Architecture — Option B (Central Traefik on Manager)

```
Internet → DNS (*.yourdomain.com → Manager public IP)
              │
              ▼
  Manager VPS (CX11)  — single public entry point
  ┌─────────────────────────────────────────┐
  │  Dokploy dashboard  :3000               │
  │  Traefik  :80 / :443                   │
  │  Reads traefik-routes.yaml (file prov.) │
  └──────────────────┬──────────────────────┘
                     │ Hetzner Private Network (10.0.0.0/24)
                     │ plain HTTP (SSL terminates at Manager)
                     ▼
  Agent VPS (CX32)  — no public HTTP/S ports
  ┌────────────────────────────────────────────────────┐
  │  mariadb-database  (compose.mariadb-shared.yaml)   │
  │  cafirm bench      frontend → 10.0.0.2:8080        │
  │  retail bench      frontend → 10.0.0.2:8081        │
  └────────────────────────────────────────────────────┘

  Scale: provision new Agent → register in Dokploy → add routes to traefik-routes.yaml
```

**Routing:** Manager Traefik reads `traefik-routes.yaml` and routes each hostname to the
correct Agent:port. Agent containers are NOT reachable from the public internet.

---

## Files in this directory (safe to commit — no real secrets)

| File                          | Purpose                                           |
| ----------------------------- | ------------------------------------------------- |
| `mariadb.env.example`         | Template for MariaDB env vars                     |
| `cafirm.env.example`          | Template for cafirm bench env vars                |
| `traefik-routes.yaml.example` | Template for Manager Traefik routing config       |
| `dms.env.example`             | Template for dms-tenant bench env vars (Videojet) |
| `lucoze.env.example`          | Template for lucoze-tenant bench env vars         |
| `lucoze-admin.env.example`    | Template for lucoze-admin bench env vars          |

## Files that live on servers (never commit — real passwords/IPs)

```
Manager ~/gitops/
└── traefik-routes.yaml   ← Traefik routing: domains → Agent IPs + ports
                            Paste into Dokploy UI → Settings → Traefik → Advanced Config

Agent ~/gitops/
├── mariadb.env           ← copy of mariadb.env.example with real DB_PASSWORD
├── cafirm.env            ← copy of cafirm.env.example with real values
└── cafirm.yaml           ← generated compose file (see below)
```

---

## Generating a bench compose file (run on LOCAL machine)

```bash
# Copy template and fill in real values
cp gitops/cafirm.env.example /tmp/cafirm.env
# Edit /tmp/cafirm.env:
#   DB_PASSWORD=<same as mariadb.env>
#   AGENT_PRIVATE_IP=10.0.0.2
#   BENCH_PORT=8080

# Generate static compose file (resolves all env vars)
docker compose \
  --env-file /tmp/cafirm.env \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.agent.yaml \
  config > /tmp/cafirm.yaml

# Upload to Agent server
scp /tmp/cafirm.yaml root@<agent-ip>:~/gitops/cafirm.yaml

# Clean up
rm /tmp/cafirm.env /tmp/cafirm.yaml
```

In **Dokploy UI → New Application → Docker Compose**:

- Target server: **Agent VPS**
- Paste contents of `cafirm.yaml`
- Deploy

---

## Configuring Manager Traefik routing

After deploying the bench on Agent, tell Manager Traefik which domains map to it:

```bash
# On MANAGER VPS:
cp gitops/traefik-routes.yaml.example ~/gitops/traefik-routes.yaml
# Edit with real domain names and Agent private IP + bench port
```

Then in **Dokploy UI → Settings → Traefik → Advanced Config**:

- Paste the full contents of `~/gitops/traefik-routes.yaml`
- Save — Traefik picks up changes immediately (no restart needed)

---

## Adding the dms-tenant bench (Videojet) — `--no-interpolate` + Dokploy Environment tab pattern

The dms-tenant bench (Videojet) uses a slightly different upload pattern from cafirm / lucoze. **All `${ENV_VAR}` placeholders stay literal in the uploaded yaml** so Dokploy's per-application Environment tab is the single source of truth for env values. No env values are baked into the yaml that gets uploaded.

Why: rotating `DB_PASSWORD` or bumping `CUSTOM_TAG` happens in the Dokploy UI alone — no compose-file regeneration, no re-upload. Also prevents secrets from leaking into Dokploy backups of the application yaml.

### 1. Generate the merged compose yaml (on LOCAL machine)

```bash
docker compose \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.agent.yaml \
  config --no-interpolate > /tmp/dms.yaml
```

`--no-interpolate` is the critical flag. It tells `docker compose config` to merge the override files but **leave `${VAR}` placeholders intact**. Skip it and every env var gets resolved against your local shell, baking values into the yaml.

### 2. Upload to Dokploy

- Dokploy UI → New Application → Docker Compose
- Target server: Agent VPS
- Paste contents of `/tmp/dms.yaml`
- Application name: `dms-uat` (or `dms` for production)

### 3. Fill in the Environment tab

Dokploy application → Environment tab → paste each variable from `gitops/dms.env.example` with the real value:

| Key                | Example value                                           |
| ------------------ | ------------------------------------------------------- |
| `CUSTOM_IMAGE`     | `svasamm/dms-tenant`                                    |
| `CUSTOM_TAG`       | `uat-latest` (UAT) or `latest` (prod)                   |
| `PULL_POLICY`      | `always`                                                |
| `DB_HOST`          | `mariadb-database`                                      |
| `DB_PORT`          | `3306`                                                  |
| `DB_PASSWORD`      | _(same as MariaDB env)_                                 |
| `ROUTER`           | `dms-uat` (UAT) or `dms` (prod)                         |
| `AGENT_PRIVATE_IP` | `10.0.0.2`                                              |
| `BENCH_PORT`       | `8085` (UAT) or `8086` (prod)                           |
| `SITES_RULE`       | _used in Traefik config, not here — kept for reference_ |

### 4. Deploy

Dokploy → dms-uat application → Deploy. CI will redeploy automatically on the next image build once `DOKPLOY_DMS_UAT_WEBHOOK` is wired (see `.github/workflows/build-dms-uat.yml` for the secret name).

### 5. Update Manager Traefik routing

On the MANAGER VPS, add the dms-uat (and later dms) router + service blocks from `gitops/traefik-routes.yaml.example` to `~/gitops/traefik-routes.yaml`, then paste the full contents into Dokploy UI → Settings → Traefik → Advanced Config.

### Migrating Lucoze to this pattern (future cleanup)

The same `--no-interpolate` + Environment-tab pattern can replace Lucoze's current "compose config locally → upload resolved yaml" flow. Out of scope for the Videojet rollout but a clear next step for the Hostinger doc-cleanup pass.

---

## Adding a new client site to an existing bench

1. On LOCAL machine: edit `/tmp/cafirm.env` — update `SITES_RULE` to add new domain
2. Regenerate and upload `cafirm.yaml` (run the `docker compose config` command above)
3. In Dokploy → cafirm app → update compose → redeploy
4. On MANAGER: update `cafirm-http/https` router rule in `traefik-routes.yaml` to include new domain
5. Re-paste updated config in Dokploy → Settings → Traefik → Advanced Config
6. Create the Frappe site (run in backend container via Dokploy terminal):

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

## Adding a new bench to an existing agent

1. Pick a new `BENCH_PORT` (e.g., `8081` for retail bench — must be unique per agent)
2. Create new env file (e.g., `/tmp/retail.env`) with new `ROUTER` and `BENCH_PORT`
3. Generate compose file and deploy to same Agent via Dokploy
4. Add new router+service block in `traefik-routes.yaml` for the new bench
5. Update Dokploy Traefik config

---

## Scaling: adding a new Agent VPS

1. Provision a new Hetzner CX32 (attach to `svasamm-net` private network)
2. Run `scripts/setup-agent.sh` on it
3. Dokploy Manager → Servers → Add Server → enter new agent's SSH details
4. Deploy benches targeting the new agent from Dokploy UI
5. Add new router+service blocks in `traefik-routes.yaml` with new Agent private IP

**Keep a port assignment record:**

| Agent   | Private IP | Bench              | Port |
| ------- | ---------- | ------------------ | ---- |
| agent-1 | 10.0.0.2   | cafirm             | 8080 |
| agent-1 | 10.0.0.2   | retail (future)    | 8081 |
| agent-1 | 10.0.0.2   | lucoze-admin       | 8082 |
| agent-1 | 10.0.0.2   | lucoze (tenant)    | 8083 |
| agent-1 | 10.0.0.2   | lucoze-website     | 8084 |
| agent-1 | 10.0.0.2   | dms-uat (Videojet) | 8085 |
| agent-1 | 10.0.0.2   | dms (Videojet)     | 8086 |
| agent-2 | 10.0.0.3   | cafirm (future)    | 8080 |
