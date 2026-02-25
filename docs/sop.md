# Svasamm Frappe SaaS — Standard Operating Procedures

> **Scope:** This document covers everything needed to develop, release, deploy, and maintain the Svasamm multi-client Frappe SaaS platform.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Secrets & Configuration Reference](#3-secrets--configuration-reference)
4. [Development Workflow](#4-development-workflow)
5. [Release & Deployment Process](#5-release--deployment-process)
6. [Adding a New Client / Product](#6-adding-a-new-client--product)
7. [Infrastructure Management](#7-infrastructure-management)
8. [Traefik Routing Management](#8-traefik-routing-management)
9. [Site Management](#9-site-management)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architecture Overview

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │  Manager VPS │  Single public IP
                    │  Traefik     │  SSL termination
                    │  Dokploy     │  Deployment control
                    └──────┬───────┘
                           │ Hetzner private network (10.0.0.0/24)
              ┌────────────┼────────────┐
              │                         │
       ┌──────▼──────┐          ┌───────▼─────┐
       │  UAT Agent   │          │  Prod Agent  │
       │  10.0.0.3    │          │  10.0.0.2    │
       │  MariaDB     │          │  MariaDB     │
       │  cafirm-uat  │          │  cafirm-prod │
       │  port 8081   │          │  port 8080   │
       └─────────────┘          └─────────────┘
```

**Key principles:**
- Manager has the only public IP. Agents have no public HTTP/S.
- Traefik on Manager routes by hostname to the correct Agent + port.
- Dokploy on Manager SSH-deploys to Agents via private network.
- Each Agent runs MariaDB once (shared across all benches on that agent).
- Each bench has its own Redis (bundled in the bench compose stack).

---

## 2. Repository Structure

### frappe_docker (this repo — `svasamm-research/frappe_docker`, branch `svasamm/base`)

```
frappe_docker/
├── apps/
│   ├── cafirm.json          ← prod app list (main branches)
│   └── cafirm-uat.json      ← UAT app list (develop branches)
├── overrides/
│   ├── compose.agent.yaml   ← Option B bench override (no Traefik labels)
│   ├── compose.redis.yaml   ← Redis bundled with bench
│   └── compose.mariadb-shared.yaml  ← standalone MariaDB (one per agent)
├── gitops/
│   └── README.md            ← Option B setup guide
├── docs/
│   └── sop.md               ← this document
└── .github/workflows/
    ├── build-custom-image.yml     ← reusable build workflow
    ├── build-cafirm.yml           ← cafirm production build
    └── build-cafirm-uat.yml       ← cafirm UAT build
```

### Custom app repos (in `svasamm-research` org)

| Repo | Purpose | Branch model |
|------|---------|--------------|
| `cafirm_override` | cafirm Frappe customizations | `develop` (UAT) → `main` (prod) |
| `site_override` | cross-client site customizations | `develop` → `main` |

Each custom app repo contains:
```
.github/workflows/
  trigger-image-build.yml   ← dispatches frappe_docker builds on push/release
```

---

## 3. Secrets & Configuration Reference

### GitHub Secrets — `svasamm-research/frappe_docker`

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username (e.g. `mithunsvasamm`) |
| `DOCKERHUB_TOKEN` | Docker Hub token — **read+write** (for CI push) |
| `CAFIRM_APPS_JSON_BASE64` | base64 of `apps/cafirm.json` with HTTPS+PAT URLs (main branches) |
| `CAFIRM_UAT_APPS_JSON_BASE64` | base64 of `apps/cafirm-uat.json` with HTTPS+PAT URLs (develop branches) |
| `DOKPLOY_CAFIRM_WEBHOOK` | Dokploy redeploy webhook for cafirm production bench |
| `DOKPLOY_CAFIRM_UAT_WEBHOOK` | Dokploy redeploy webhook for cafirm UAT bench |

### GitHub Variables — `svasamm-research/frappe_docker`

| Variable | Value | Effect |
|----------|-------|--------|
| `DOKPLOY_DEPLOY_ENABLED` | `true` | Enables auto-redeploy after successful image build |

### GitHub Secrets — `cafirm_override`

| Secret | Description |
|--------|-------------|
| `FRAPPE_DOCKER_WORKFLOW_TOKEN` | GitHub PAT with `workflow` scope on `frappe_docker` repo |

### GitHub Environments — `svasamm-research/frappe_docker`

| Environment | Protection rules |
|-------------|-----------------|
| `uat` | None — auto-deploys on successful build |
| `production` | Required reviewers — must approve before deploy step runs |

### Generating apps.json secrets

The `apps.json` files committed in the repo use `git+ssh://` URLs (for local testing).
The base64 secrets used in CI must use **HTTPS + PAT** URLs so GitHub Actions can clone private repos without SSH keys.

**Template for HTTPS apps.json (do not commit — only store as secret):**
```json
[
  {"url": "https://github.com/frappe/erpnext", "branch": "version-16"},
  {"url": "https://github.com/frappe/hrms", "branch": "version-16"},
  {"url": "https://github.com/resilient-tech/india-compliance", "branch": "version-16"},
  {"url": "https://<PAT>@github.com/svasamm-research/site-override.git", "branch": "develop"},
  {"url": "https://<PAT>@github.com/svasamm-research/cafirm-project-override.git", "branch": "develop"}
]
```

**To create the base64 secret:**
```bash
# UAT
cat apps/cafirm-uat-https.json | base64 -w 0
# Prod
cat apps/cafirm-https.json | base64 -w 0
```
Paste the output as the GitHub Secret value.

---

## 4. Development Workflow

### Branching model (custom app repos)

```
main       ←─── production (never commit directly)
  ▲
  │  PR (develop → main, reviewed before release)
  │
develop    ←─── all feature work merged here
  ▲
  │  PR (feature → develop)
  │
feature/my-feature
```

### Day-to-day development

```
1. Create feature branch from develop:
   git checkout develop && git pull
   git checkout -b feature/my-feature

2. Make changes, commit, push:
   git push origin feature/my-feature

3. Open PR → develop (code review)

4. Merge PR → develop
   → trigger-image-build.yml dispatches build-cafirm-uat.yml
   → frappe-cafirm:develop image built & pushed to Docker Hub
   → (if DOKPLOY_DEPLOY_ENABLED=true) UAT bench auto-redeployed

5. Test on UAT site (testca-uat.svasamm.com)

6. Repeat until UAT is stable
```

### What triggers what

| Action | Trigger | Result |
|--------|---------|--------|
| Push to `develop` in `cafirm_override` | `trigger-image-build.yml` | `frappe-cafirm:develop` built |
| Push to `develop` in `site_override` | `trigger-image-build.yml` | same — both repos share the image |
| Push to `svasamm/base` (infra change) | `build-cafirm-uat.yml` push trigger | UAT image rebuilt with new Containerfile |
| Create GitHub Release in `cafirm_override` | `trigger-image-build.yml` | `frappe-cafirm:v1.0.0` built |

---

## 5. Release & Deployment Process

### UAT Deployment

UAT deploys automatically when `develop` is pushed. No manual steps required once `DOKPLOY_DEPLOY_ENABLED=true` and `DOKPLOY_CAFIRM_UAT_WEBHOOK` are set.

Manual UAT redeploy (if needed):
1. GitHub → `frappe_docker` → Actions → "Build cafirm — UAT" → Run workflow

### Production Deployment (step-by-step)

Production deploys are **always explicit**. A GitHub Release is the gate.

```
Step 1: Ensure UAT is stable and tested.

Step 2: In cafirm_override — merge develop → main
  git checkout main && git merge develop && git push

Step 3: Create GitHub Release in cafirm_override
  GitHub → cafirm_override → Releases → Draft a new release
  Tag: v1.0.0  (format must be vX.Y.Z)
  Title: v1.0.0 — brief description
  Publish Release

Step 4: trigger-image-build.yml fires automatically
  → dispatches build-cafirm.yml in frappe_docker with version=v1.0.0

Step 5: frappe_docker CI runs:
  ├── validate-version job (checks vX.Y.Z format)
  ├── build job (frappe-cafirm:v1.0.0 + :v1.0.0-{sha7} pushed to Docker Hub)
  └── deploy job (waits for environment approval → triggers Dokploy webhook)

Step 6: (if environment protection enabled) Approve deploy in GitHub UI
  frappe_docker → Actions → running workflow → Review deployments → Approve

Step 7: Dokploy redeployes production bench with new image
  Bench pulls frappe-cafirm:v1.0.0 and restarts services.

Step 8: Verify production site is healthy.
```

### Version numbering

| Version part | When to increment |
|-------------|------------------|
| `v1.0.0` → `v1.0.1` | Bug fix or minor change |
| `v1.0.0` → `v1.1.0` | New feature added |
| `v1.0.0` → `v2.0.0` | Breaking change or major upgrade |

---

## 6. Adding a New Client / Product

Example: adding `retail` client alongside `cafirm`.

### Step 1 — Create custom app repo

Create `svasamm-research/retail_override` with:
```
.github/workflows/trigger-image-build.yml
  ← copy from cafirm_override, change workflow filenames to build-retail*.yml
```

### Step 2 — Add apps.json files to frappe_docker

```bash
# apps/retail.json — prod (main branches)
# apps/retail-uat.json — UAT (develop branches)
```
Same structure as cafirm, pointing to retail custom apps.

### Step 3 — Add build workflows to frappe_docker

Copy and rename:
```
.github/workflows/build-cafirm.yml     → build-retail.yml
.github/workflows/build-cafirm-uat.yml → build-retail-uat.yml
```
Update: `image_name: frappe-retail`, secret names `RETAIL_*`, environment `uat`/`production`.

### Step 4 — Add GitHub Secrets

In `svasamm-research/frappe_docker`:
- `RETAIL_APPS_JSON_BASE64`
- `RETAIL_UAT_APPS_JSON_BASE64`
- `DOKPLOY_RETAIL_WEBHOOK`
- `DOKPLOY_RETAIL_UAT_WEBHOOK`

### Step 5 — Assign bench port on agent

| Client | Agent | Port | Domain |
|--------|-------|------|--------|
| cafirm prod | Prod Agent (10.0.0.2) | 8080 | testca.svasamm.com |
| cafirm UAT | UAT Agent (10.0.0.3) | 8081 | testca-uat.svasamm.com |
| retail prod | Prod Agent (10.0.0.2) | 8082 | retail.svasamm.com |
| retail UAT | UAT Agent (10.0.0.3) | 8083 | retail-uat.svasamm.com |

Ports must be unique **per agent**. Different agents can reuse the same port.

### Step 6 — Add DNS + Traefik route

DNS (GoDaddy): add A record `retail` → Manager public IP.

Traefik (Manager Dokploy → Traefik File System → `dynamic/svasamm-routes.yml`):
add new router + service entry pointing to `http://10.0.0.2:8082`.

### Step 7 — Deploy bench and create site

```bash
# Generate retail.yaml
docker compose \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.agent.yaml \
  --env-file /tmp/retail.env \
  config > /tmp/retail.yaml

# Deploy via Dokploy, then in backend container:
bench new-site \
  --mariadb-user-host-login-scope='%' \
  --db-root-password <DB_PASSWORD> \
  --admin-password <ADMIN_PASSWORD> \
  --install-app erpnext \
  --install-app retail_override \
  retail.svasamm.com
```

---

## 7. Infrastructure Management

### Adding a new Agent VPS

```bash
# 1. Create VPS on Hetzner — attach to same private network (10.0.0.0/24)

# 2. SSH in and run setup script
curl -fsSL https://raw.githubusercontent.com/svasamm-research/frappe_docker/svasamm/base/scripts/setup-agent.sh | bash

# 3. Note the private IP shown in script output (e.g. 10.0.0.4)

# 4. Register in Dokploy
#    Manager Dokploy UI → Servers → Add Server
#    → SSH key: the key that has access to this VPS
#    → IP: 10.0.0.4 (private)
#    Dokploy installs its agent component automatically

# 5. Deploy MariaDB on new agent
#    Dokploy → New Application → Docker Compose → Server: new agent
#    → paste contents of overrides/compose.mariadb-shared.yaml
#    → Env: DB_PASSWORD=<strong-unique-password>
#    → Deploy

# 6. Deploy benches to new agent (see Section 6 Step 7)
```

### Agent port assignment table

Keep this table updated as benches are added.

| Agent IP | Client | Environment | Port |
|----------|--------|-------------|------|
| 10.0.0.2 | cafirm | production | 8080 |
| 10.0.0.3 | cafirm | UAT | 8081 |

---

## 8. Traefik Routing Management

Traefik on Manager reads `dynamic/svasamm-routes.yml` via the file provider.
Access via: **Manager Dokploy UI → Traefik → Traefik File System → `dynamic/`**

### Template for `svasamm-routes.yml`

```yaml
http:
  routers:
    # ── cafirm UAT ─────────────────────────────────────
    cafirm-uat-https:
      rule: "Host(`testca-uat.svasamm.com`)"
      service: cafirm-uat
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt

    cafirm-uat-http:
      rule: "Host(`testca-uat.svasamm.com`)"
      service: cafirm-uat
      entryPoints: [web]
      middlewares: [redirect-https]

    # ── cafirm production ──────────────────────────────
    cafirm-https:
      rule: "Host(`testca.svasamm.com`)"
      service: cafirm-prod
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt

    cafirm-http:
      rule: "Host(`testca.svasamm.com`)"
      service: cafirm-prod
      entryPoints: [web]
      middlewares: [redirect-https]

  services:
    cafirm-uat:
      loadBalancer:
        servers:
          - url: "http://10.0.0.3:8081"

    cafirm-prod:
      loadBalancer:
        servers:
          - url: "http://10.0.0.2:8080"

  middlewares:
    redirect-https:
      redirectScheme:
        scheme: https
        permanent: true
```

Traefik picks up changes immediately — no restart needed.

---

## 9. Site Management

### Creating a new Frappe site

In Dokploy → bench application → Terminal → `backend` container:

```bash
# Check what apps are available in this image
bench list-apps

# Create site (replace placeholders)
bench new-site \
  --mariadb-user-host-login-scope='%' \
  --db-root-password <DB_PASSWORD> \
  --admin-password <ADMIN_PASSWORD> \
  --install-app erpnext \
  --install-app hrms \
  --install-app india_compliance \
  --install-app <custom_app_name> \
  <site-domain.com>
```

After creating the site:
1. In Dokploy → bench application → Environment: set `SITES=site-domain.com`
   (for multiple sites: `SITES=site1.com,site2.com`)
2. Redeploy the application (restarts nginx configurator with new site list)

### Adding a site to an existing bench

```bash
# In backend container:
bench new-site --mariadb-user-host-login-scope='%' \
  --db-root-password <DB_PASSWORD> --admin-password <ADMIN_PASSWORD> \
  --install-app erpnext ... \
  newclient.svasamm.com

# Update SITES env var in Dokploy (comma-separated):
SITES=existingclient.svasamm.com,newclient.svasamm.com

# Redeploy bench
```

Also add the new domain to Traefik routing (update `svasamm-routes.yml`).

### Updating apps on a site

When a new image is deployed (via CI), benches restart automatically.
Run migrations if needed:
```bash
# In backend container:
bench --site <site-name> migrate
```

Or run for all sites:
```bash
bench --all migrate
```

---

## 10. Troubleshooting

### `mariadb-network not found` on bench deploy

The shared MariaDB network doesn't exist on the target agent.

```bash
# SSH into the agent, then:
docker network create \
  --driver bridge \
  --opt com.docker.network.bridge.name=br-mariadb \
  mariadb-network
# Then redeploy bench from Dokploy UI
```

### Pull access denied for Docker image

Either:
- Image doesn't exist yet (CI hasn't run) → trigger CI manually
- Docker Hub credentials not set in Dokploy → Dokploy → Registries → add Docker Hub creds

### Site not loading — `502 Bad Gateway`

Traefik can reach the Agent but bench isn't responding.
```bash
# Check bench services on agent:
docker ps | grep <bench-name>
# Check frontend logs:
docker logs <frontend-container>
```

### Site not loading — `404 from Traefik`

Traefik has no route for the hostname.
- Verify `svasamm-routes.yml` has the correct `Host()` rule for the domain
- Verify DNS A record points to Manager public IP (`dig testca.svasamm.com`)

### `ERPNEXT_VERSION` warning during docker compose config

Not an error — Docker Compose resolves all variable fallbacks at parse time.
Suppress it by adding `ERPNEXT_VERSION=version-16` to the env file.

### CI builds but custom private repo clone fails

The `APPS_JSON_BASE64` secret must use **HTTPS + PAT URLs** (not `git+ssh://`).
Regenerate the secret using the HTTPS template in Section 3.

### Bench not redeploying after new image push

Check:
1. `DOKPLOY_DEPLOY_ENABLED=true` (GitHub Variable in frappe_docker)
2. `DOKPLOY_CAFIRM_UAT_WEBHOOK` (or prod equivalent) secret is set
3. Webhook is valid — test it manually:
   ```bash
   curl -X POST "<webhook-url>" -H "Content-Type: application/json"
   ```

---

*Last updated: see git log. Always refer to the git history for specific version changes.*
