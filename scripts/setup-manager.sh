#!/usr/bin/env bash
# =============================================================================
# Manager VPS Bootstrap — Svasamm Frappe Stack
# =============================================================================
# Run ONCE on the MANAGER VPS (CX11/CX21) as root.
#
# Role: Orchestration ONLY — Dokploy dashboard + Traefik reverse proxy.
#       No Frappe containers or databases run here.
#       All workloads (MariaDB, benches) live on Agent VPSes.
#
# Architecture:
#
#   ┌─────────────────────────┐     Hetzner Private Network (10.0.0.0/24)
#   │  Manager VPS (CX11)     ��────────────────────────────────┐
#   │  Public IP ← all DNS    │                                │
#   │  Dokploy dashboard:3000 │     ┌──────────────────────────┴──────┐
#   │  Traefik :80 :443       │────▶│  Agent VPS (CX32) 10.0.0.2     │
#   └─────────────────────────┘     │  MariaDB (shared)               │
#                                   │  cafirm bench (Frappe)          │
#     Add more agents as load grows │  retail bench (future)          │
#                                   └─────────────────────────────────┘
#
# Prerequisites — do in Hetzner Cloud Console BEFORE running this script:
#   1. Create Private Network: name=svasamm-net, subnet=10.0.0.0/24
#   2. Provision Manager VPS (CX11) — attach to svasamm-net → run THIS script
#   3. Provision Agent VPS (CX32)   — attach to svasamm-net → run setup-agent.sh
#   4. Point DNS: *.yourdomain.com → Manager public IP
#
# Usage:
#   ssh root@<manager-ip>
#   curl -fsSL https://raw.githubusercontent.com/svasamm-research/frappe_docker/svasamm/base/scripts/setup-manager.sh | bash
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

# Manager exposes only: SSH, HTTP/S (Traefik), and Dokploy UI.
# Agents are NOT publicly exposed — traffic flows through Manager's Traefik.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP  — Traefik (ACME challenge + HTTP→HTTPS redirect)'
ufw allow 443/tcp  comment 'HTTPS — Traefik entry point for all client sites'
ufw allow 3000/tcp comment 'Dokploy dashboard — RESTRICT TO YOUR IP AFTER SETUP'
ufw --force enable

info "UFW active. Open: 22, 80, 443, 3000"
warn "After finishing Dokploy setup, lock down port 3000:"
warn "  ufw delete allow 3000/tcp"
warn "  ufw allow from <YOUR_IP> to any port 3000 proto tcp"

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
# 4. Dokploy
# =============================================================================
section "4/4 — Dokploy"

# Dokploy installs:
#   - Dokploy dashboard container (port 3000)
#   - Traefik container (ports 80/443) — the SINGLE entry point for all sites
#   - dokploy-network (Docker bridge network Traefik uses to discover services)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "dokploy"; then
  info "Dokploy already running — skipping."
else
  curl -sSL https://dokploy.com/install.sh | sh
  info "Dokploy installed."
fi

# =============================================================================
# Summary & Next Steps
# =============================================================================
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<manager-public-ip>")

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Manager VPS setup complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Dokploy  →  http://${PUBLIC_IP}:3000"
echo ""
echo -e "${YELLOW}What to do now (in order):${NC}"
echo ""
echo -e "  ${CYAN}A. Complete Dokploy initial setup${NC}"
echo "     1. Open http://${PUBLIC_IP}:3000 → create admin account"
echo "     2. Settings → Registries → Add Docker Hub credentials"
echo "        (for pulling private svasamm/frappe-* images on agents)"
echo ""
echo -e "  ${CYAN}B. Set up Agent VPS (run setup-agent.sh on it first)${NC}"
echo "     1. SSH into your Agent VPS and run:"
echo "        curl -fsSL .../scripts/setup-agent.sh | bash"
echo "     2. In Dokploy → Servers → Add Server"
echo "        → Agent private IP (10.0.0.2) + SSH key"
echo "        → Dokploy installs its agent component remotely"
echo ""
echo -e "  ${CYAN}C. Deploy on Agent via Dokploy UI${NC}"
echo "     1. MariaDB  → New App → Docker Compose → target Agent → paste compose.mariadb-shared.yaml"
echo "     2. cafirm   → New App → Docker Compose → target Agent → paste generated cafirm.yaml"
echo "        (see gitops/README.md for how to generate cafirm.yaml)"
echo ""
echo -e "  ${CYAN}D. Harden after setup${NC}"
echo "     ufw delete allow 3000/tcp"
echo "     ufw allow from <YOUR_IP> to any port 3000"
echo ""
