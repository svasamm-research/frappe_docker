#!/usr/bin/env bash
# =============================================================================
# Hetzner VPS Bootstrap — Svasamm Frappe Stack
# =============================================================================
# Run this script once on a fresh Ubuntu 22.04 / 24.04 VPS as root (or sudo).
#
# What this does:
#   1. System hardening (UFW firewall, SSH tweaks)
#   2. Docker CE installation (official method)
#   3. Dokploy installation (manages Traefik, deploy UI, webhooks)
#   4. Shared Docker networks (mariadb-network used by all benches)
#   5. Login to Docker Hub (for pulling private images)
#
# Usage:
#   ssh root@<hetzner-ip>
#   curl -fsSL https://raw.githubusercontent.com/svasamm-research/frappe_docker/svasamm/base/scripts/setup-hetzner.sh | bash
#
#   OR copy the file and run:
#   chmod +x setup-hetzner.sh && sudo ./setup-hetzner.sh
# =============================================================================

set -euo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${GREEN}========================================${NC}"; \
            echo -e "${GREEN} $*${NC}"; \
            echo -e "${GREEN}========================================${NC}\n"; }

# --- Root check --------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
  error "Run this script as root or with sudo."
fi

# =============================================================================
# 1. System Update & Essentials
# =============================================================================
section "1/5 — System Update"

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git ufw unzip \
  ca-certificates gnupg lsb-release \
  htop fail2ban

info "System packages updated."

# =============================================================================
# 2. Firewall (UFW)
# =============================================================================
section "2/5 — Firewall Setup"

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP  — Traefik (Let'\''s Encrypt challenge + redirect)'
ufw allow 443/tcp   comment 'HTTPS — Traefik'
ufw allow 3000/tcp  comment 'Dokploy dashboard (restrict to trusted IPs after setup)'
ufw --force enable

info "UFW configured. Open ports: 22, 80, 443, 3000"
warn "Restrict port 3000 to your IP after Dokploy initial setup:"
warn "  ufw delete allow 3000/tcp"
warn "  ufw allow from <YOUR_IP> to any port 3000 proto tcp"

# =============================================================================
# 3. Docker CE
# =============================================================================
section "3/5 — Docker CE"

if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version)
  info "Docker already installed: $DOCKER_VERSION — skipping."
else
  info "Installing Docker CE via official install script..."
  curl -fsSL https://get.docker.com | bash

  # Add the default non-root user (ubuntu) to docker group so they can run
  # docker commands without sudo. SSH in as that user after this script.
  if id "ubuntu" &>/dev/null; then
    usermod -aG docker ubuntu
    info "Added 'ubuntu' user to docker group."
  fi

  systemctl enable docker
  systemctl start docker
  info "Docker CE installed: $(docker --version)"
fi

# =============================================================================
# 4. Dokploy
# =============================================================================
section "4/5 — Dokploy"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "dokploy"; then
  info "Dokploy already running — skipping install."
else
  info "Installing Dokploy..."
  # Official Dokploy install — sets up Traefik, creates dokploy-network,
  # and starts the Dokploy management container on port 3000.
  curl -sSL https://dokploy.com/install.sh | sh

  info "Dokploy installed."
  info "Access the Dokploy dashboard at: http://$(curl -s ifconfig.me):3000"
  info "Complete initial setup in the browser, then return here."
fi

# =============================================================================
# 5. Shared Docker Networks
# =============================================================================
section "5/5 — Shared Docker Networks"

# dokploy-network is created by Dokploy during installation.
# We wait for it to exist before proceeding.
RETRIES=10
until docker network ls --format '{{.Name}}' | grep -q "^dokploy-network$" || [[ $RETRIES -eq 0 ]]; do
  info "Waiting for dokploy-network to be created by Dokploy... ($RETRIES retries left)"
  sleep 3
  ((RETRIES--))
done

if docker network ls --format '{{.Name}}' | grep -q "^dokploy-network$"; then
  info "dokploy-network exists."
else
  warn "dokploy-network not found. Dokploy may not have finished starting."
  warn "Run manually after Dokploy starts: docker network create dokploy-network"
fi

# mariadb-network is shared across ALL benches on this server.
# Created here once; referenced as external: true in all bench compose files.
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
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<server-ip>")

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Server setup complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Dokploy dashboard : http://${SERVER_IP}:3000"
echo "  Docker version    : $(docker --version)"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Open http://${SERVER_IP}:3000 — complete Dokploy initial setup"
echo "  2. In Dokploy → Settings → Registries → Add Docker Hub credentials"
echo "     (needed for pulling private svasamm/frappe-* images)"
echo "  3. Deploy MariaDB via Dokploy using:"
echo "     frappe_docker/overrides/compose.mariadb-shared.yaml"
echo "     Env var: DB_PASSWORD=<strong-password>"
echo "  4. Deploy cafirm bench using the gitops/cafirm.yaml"
echo "     (generate it on your local machine first — see gitops/README.md)"
echo "  5. Restrict Dokploy port after setup:"
echo "     ufw delete allow 3000/tcp"
echo "     ufw allow from <YOUR_IP> to any port 3000 proto tcp"
echo ""
