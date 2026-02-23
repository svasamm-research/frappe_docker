#!/usr/bin/env bash
# =============================================================================
# Agent VPS Bootstrap — Svasamm Frappe Stack
# =============================================================================
# Run ONCE on each AGENT VPS (CX32 or larger) as root.
#
# Role: Runs all actual workloads — MariaDB and Frappe benches.
#       Publicly not accessible directly. Traefik on the Manager routes
#       all traffic to containers running on this agent.
#       Dokploy manager SSH's in and manages deployments remotely.
#
# What this does:
#   1. System update
#   2. Firewall — SSH only from public; no public HTTP/S (Traefik is on Manager)
#   3. Docker CE
#   4. Shared Docker networks for this agent's workloads
#
# IMPORTANT: After running this script, register this server in Dokploy:
#   Manager Dokploy UI → Servers → Add Server → enter this VPS's SSH details.
#   Dokploy will install its agent component remotely.
#
# Usage:
#   ssh root@<agent-ip>
#   curl -fsSL https://raw.githubusercontent.com/svasamm-research/frappe_docker/svasamm/base/scripts/setup-agent.sh | bash
#
# Scaling: run this script on each new Agent VPS, then register it in Dokploy.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${CYAN}  $*${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════${NC}\n"; }

[[ "$EUID" -ne 0 ]] && error "Run as root or with sudo."

# =============================================================================
# 1. System
# =============================================================================
section "1/4 — System Update"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget ufw ca-certificates gnupg htop fail2ban
info "System updated."

# =============================================================================
# 2. Firewall
# =============================================================================
section "2/4 — Firewall (UFW)"

# Agent is NOT publicly reachable (Option B: Central Traefik on Manager).
# All HTTP/S traffic comes from Manager Traefik via Hetzner private network.
#
# Rules:
#   22/tcp  — SSH from anywhere (admin + Dokploy manager remote deployments)
#   10.0.0.0/24 — all traffic from private network allowed (Manager→Agent routing
#                 on bench ports 8080+ and any internal Dokploy communication)
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH — admin access and Dokploy manager deployments'
ufw allow from 10.0.0.0/24 comment 'Hetzner private network — Manager Traefik routing and Dokploy'
ufw --force enable

info "UFW active. Open: port 22 (public) + all from 10.0.0.0/24 (private network)."
info "Bench ports (8080, 8081, ...) are reachable from Manager only via private network."

# =============================================================================
# 3. Docker CE
# =============================================================================
section "3/4 — Docker CE"

if command -v docker &>/dev/null; then
  info "Already installed: $(docker --version) — skipping."
else
  curl -fsSL https://get.docker.com | bash
  id ubuntu &>/dev/null && usermod -aG docker ubuntu && info "Added 'ubuntu' to docker group."
  systemctl enable --now docker
  info "Installed: $(docker --version)"
fi

# =============================================================================
# 4. Shared Docker Networks
# =============================================================================
section "4/4 — Shared Docker Networks"

# dokploy-network: Dokploy manager installs this when registering the agent.
# We do NOT create it here — Dokploy owns it.

# mariadb-network: shared across ALL benches on THIS agent.
# MariaDB container and all Frappe bench containers join this network.
# Created once per agent; never recreated (persistent across deploys).
if docker network ls --format '{{.Name}}' | grep -q "^mariadb-network$"; then
  info "mariadb-network already exists — skipping."
else
  docker network create \
    --driver bridge \
    --opt com.docker.network.bridge.name=br-mariadb \
    mariadb-network
  info "mariadb-network created."
fi

# =============================================================================
# Summary
# =============================================================================
PRIVATE_IP=$(ip -4 addr show | grep -oP '10\.\d+\.\d+\.\d+' | head -1 || echo "<check-hetzner-console>")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<agent-public-ip>")

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Agent VPS setup complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Public IP  : ${PUBLIC_IP}  (use this for SSH from outside)"
echo "  Private IP : ${PRIVATE_IP}  (use this when registering in Dokploy)"
echo ""
echo -e "${YELLOW}What to do now:${NC}"
echo ""
echo -e "  ${CYAN}1. Register this agent in Dokploy${NC}"
echo "     Dokploy Manager UI → Servers → Add Server"
echo "     → IP: ${PRIVATE_IP} (private) or ${PUBLIC_IP} (public)"
echo "     → SSH private key that has access to this VPS"
echo "     → Dokploy installs its agent component automatically"
echo ""
echo -e "  ${CYAN}2. Deploy MariaDB on this agent (via Dokploy UI)${NC}"
echo "     New Application → Docker Compose → Server: this agent"
echo "     → paste overrides/compose.mariadb-shared.yaml"
echo "     → Env: DB_PASSWORD=<strong-password>"
echo "     → Deploy"
echo ""
echo -e "  ${CYAN}3. Deploy cafirm bench on this agent (via Dokploy UI)${NC}"
echo "     Generate cafirm.yaml first on local machine (see gitops/README.md)"
echo "     New Application → Docker Compose → Server: this agent"
echo "     → paste cafirm.yaml → Deploy"
echo ""
echo -e "  ${CYAN}4. Create Frappe site${NC}"
echo "     Dokploy → cafirm app → terminal → backend container:"
echo "     bench new-site --mariadb-user-host-login-scope=% \\"
echo "       --db-root-password <DB_PASSWORD> \\"
echo "       --admin-password <ADMIN_PASS> \\"
echo "       --install-app erpnext --install-app hrms \\"
echo "       --install-app india_compliance --install-app cafirm_override \\"
echo "       client1.yourdomain.com"
echo ""
echo -e "  ${CYAN}Adding more capacity later${NC}"
echo "     Provision a new CX32, run this script, register in Dokploy."
echo "     Deploy new benches to any registered agent from Dokploy UI."
echo ""
