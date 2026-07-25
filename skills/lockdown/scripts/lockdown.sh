#!/usr/bin/env bash
#
# lockdown.sh — app-agnostic security baseline for a fresh Ubuntu/Debian VPS.
#
# Standalone and dependency-free: no other file in this repo is required. Safe to
# run unattended as cloud-init user-data, or by hand (ssh in as root and run it).
#
# Configuration comes from the environment:
#
#   TAILSCALE_AUTHKEY     (required)  reusable, persistent Tailscale auth key
#   TAILSCALE_HOSTNAME    (optional)  name to register in your tailnet (default: hostname)
#   CREATE_DEPLOY_USER    (optional)  "true" to create a non-root sudo user (default: true)
#   DEPLOY_USER           (optional)  name of that user (default: deploy)
#   DISABLE_ROOT_SSH      (optional)  "true" sets PermitRootLogin no (default: false)
#   ALLOW_CLOUDFLARE_WEB  (optional)  "true" opens 80/443 to Cloudflare only (default: true)
#
# SAFETY: SSH is only restricted to the Tailscale interface AFTER Tailscale is
# confirmed up. If Tailscale fails, port 22 is left open on the public IP so you are
# never locked out — the failure is logged loudly instead.
#
# Re-runnable: every step is idempotent.

set -euo pipefail

# ----- config with defaults --------------------------------------------------
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"
CREATE_DEPLOY_USER="${CREATE_DEPLOY_USER:-true}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-false}"
ALLOW_CLOUDFLARE_WEB="${ALLOW_CLOUDFLARE_WEB:-true}"

SUMMARY_LOG="/var/log/hq-lockdown.log"

log() { echo "[lockdown] $*" | tee -a "$SUMMARY_LOG" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "[lockdown] must run as root." >&2
  exit 1
fi

echo "================================================"
echo "  HQ lockdown — securing this box"
echo "  host: $TAILSCALE_HOSTNAME"
echo "================================================"

export DEBIAN_FRONTEND=noninteractive

# ----- 1. Update packages ----------------------------------------------------
log "[1/6] Updating packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ufw unattended-upgrades

# ----- 2. Unattended security upgrades ---------------------------------------
log "[2/6] Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# ----- 3. Non-root deploy user -----------------------------------------------
# Reuses the SSH key already installed for root, so the same master key logs in
# as the deploy user too.
if [ "$CREATE_DEPLOY_USER" = "true" ]; then
  log "[3/6] Creating deploy user '$DEPLOY_USER'..."
  if ! id "$DEPLOY_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
  fi
  usermod -aG sudo "$DEPLOY_USER"
  # passwordless sudo so unattended deploys don't hang on a prompt
  echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEPLOY_USER"
  chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
  if [ -f /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
      /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"
  else
    log "!! /root/.ssh/authorized_keys not found — '$DEPLOY_USER' has no SSH key."
    log "!! Tailscale SSH will still let you in as this user."
  fi
else
  log "[3/6] Skipping deploy user (CREATE_DEPLOY_USER=$CREATE_DEPLOY_USER)."
fi

# ----- 4. Tailscale (unattended join) ----------------------------------------
log "[4/6] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

TAILSCALE_UP=false
TAILSCALE_IP=""
if [ -n "$TAILSCALE_AUTHKEY" ]; then
  log "Joining tailnet as '$TAILSCALE_HOSTNAME'..."
  if tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" --ssh; then
    for _ in $(seq 1 30); do
      TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
      [ -n "$TAILSCALE_IP" ] && break
      sleep 1
    done
    if [ -n "$TAILSCALE_IP" ]; then
      TAILSCALE_UP=true
      log "Tailscale up. IP: $TAILSCALE_IP"
    else
      log "!! Tailscale joined but no tailnet IPv4 appeared within 30s."
    fi
  else
    log "!! 'tailscale up' failed — check the auth key is valid and not expired."
  fi
else
  log "!! No TAILSCALE_AUTHKEY provided — skipping Tailscale join."
fi

# ----- 5. Harden sshd --------------------------------------------------------
# Done BEFORE enabling the firewall: if you are running this over public-IP SSH,
# enabling UFW drops that session, so sshd must already be hardened by then.
log "[5/6] Hardening sshd..."
mkdir -p /etc/ssh/sshd_config.d
SSHD_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"
{
  echo "# Managed by HQ skills/lockdown — edits will be overwritten on re-run."
  echo "PasswordAuthentication no"
  echo "ChallengeResponseAuthentication no"
  echo "KbdInteractiveAuthentication no"
  if [ "$DISABLE_ROOT_SSH" = "true" ]; then
    echo "PermitRootLogin no"
  else
    echo "PermitRootLogin prohibit-password"
  fi
} > "$SSHD_CONF"
chmod 644 "$SSHD_CONF"
# Ubuntu 24.04 uses the 'ssh' unit; older releases use 'sshd'.
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }

# ----- 6. Firewall (UFW), default deny ---------------------------------------
log "[6/6] Configuring firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing

# Tailscale direct connections
ufw allow 41641/udp comment 'tailscale'

if [ "$ALLOW_CLOUDFLARE_WEB" = "true" ]; then
  log "Allowing 80/443 from Cloudflare ranges only..."
  # Prefer the live list; fall back to a pinned copy if the fetch fails.
  CF_RANGES="$(
    { curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4
      echo
      curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v6
    } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' || true
  )"
  if [ -z "$CF_RANGES" ]; then
    log "!! Could not fetch Cloudflare ranges — using pinned fallback list."
    log "!! Refresh later against https://www.cloudflare.com/ips/"
    CF_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
  fi
  for ip in $CF_RANGES; do
    ufw allow from "$ip" to any port 443 proto tcp comment 'cloudflare'
    ufw allow from "$ip" to any port 80 proto tcp comment 'cloudflare'
  done
else
  log "Skipping Cloudflare web rules (ALLOW_CLOUDFLARE_WEB=$ALLOW_CLOUDFLARE_WEB)."
  log "Ports 80/443 stay closed — open them yourself when you deploy a web app."
fi

# SSH access rule — lockout-safe
if [ "$TAILSCALE_UP" = "true" ]; then
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh via tailnet'
  ufw --force delete allow 22/tcp 2>/dev/null || true
  log "SSH restricted to the Tailscale interface only."
else
  # Fail SAFE: Tailscale unconfirmed → keep public SSH so you aren't locked out.
  ufw allow 22/tcp comment 'PUBLIC ssh — close once tailnet works'
  log "!! Tailscale NOT confirmed up — leaving PUBLIC SSH (port 22) OPEN."
  log "!! Fix Tailscale, then close it by hand: ufw delete allow 22/tcp"
fi

log "Enabling UFW (this drops any SSH session on the public IP)..."
ufw --force enable

echo ""
echo "================================================"
echo "  Lockdown complete"
echo "================================================"
if [ "$TAILSCALE_UP" = "true" ]; then
  echo "  Tailscale IP : $TAILSCALE_IP"
  echo "  SSH (root)   : ssh root@$TAILSCALE_HOSTNAME"
  [ "$CREATE_DEPLOY_USER" = "true" ] && \
  echo "  SSH (deploy) : ssh $DEPLOY_USER@$TAILSCALE_HOSTNAME"
else
  echo "  WARNING: Tailscale did not come up. Public SSH left OPEN."
  echo "  Fix Tailscale, verify tailnet access, then: ufw delete allow 22/tcp"
fi
echo "  Log          : $SUMMARY_LOG"
echo "================================================"
