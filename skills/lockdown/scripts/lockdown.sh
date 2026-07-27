#!/usr/bin/env bash
#
# lockdown.sh — app-agnostic security baseline for a fresh Ubuntu/Debian VPS.
#
# Standalone and dependency-free: no other file in this repo is required. Runs
# unattended as cloud-init user-data at first boot, or by hand from any root shell
# (the Hetzner console, or an existing Tailscale SSH session).
#
# Configuration comes from the environment:
#
#   TAILSCALE_AUTHKEY     (required)  reusable, non-ephemeral Tailscale auth key
#   TAILSCALE_HOSTNAME    (optional)  name to register in your tailnet (default: hostname)
#   TAILSCALE_TAGS        (optional)  comma-separated ACL tags, e.g. "tag:server"
#   CREATE_DEPLOY_USER    (optional)  "true" to create a non-root sudo user (default: true)
#   DEPLOY_USER           (optional)  name of that user (default: deploy)
#   ALLOW_CLOUDFLARE_WEB  (optional)  "true" opens 80/443 to Cloudflare only (default: true)
#
# Administrative access is Tailscale SSH: tailscaled itself answers port 22 on the
# tailnet address and authorizes you against your tailnet identity and SSH policy.
# There are no authorized_keys and no passwords anywhere in this baseline.
#
# SAFETY: the script aborts before touching sshd or the firewall if the tailnet join
# does not confirm, leaving the box exactly as it was rather than sealing it with no
# way back in. Break-glass is always the Hetzner console.
#
# Re-runnable: every step is idempotent.

set -euo pipefail

# ----- config with defaults --------------------------------------------------
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-}"
CREATE_DEPLOY_USER="${CREATE_DEPLOY_USER:-true}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
ALLOW_CLOUDFLARE_WEB="${ALLOW_CLOUDFLARE_WEB:-true}"

SUMMARY_LOG="/var/log/hq-lockdown.log"

log() { echo "[lockdown] $*" | tee -a "$SUMMARY_LOG" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "[lockdown] must run as root." >&2
  exit 1
fi

if [ -z "$TAILSCALE_AUTHKEY" ]; then
  echo "[lockdown] TAILSCALE_AUTHKEY is required — it is the only way back into this box." >&2
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
# No keys and no password: you reach this account through Tailscale SSH, which
# authorizes you by tailnet identity. Grant it in your SSH policy via
# "users": ["deploy"].
if [ "$CREATE_DEPLOY_USER" = "true" ]; then
  log "[3/6] Creating deploy user '$DEPLOY_USER'..."
  if ! id "$DEPLOY_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
  fi
  usermod -aG sudo "$DEPLOY_USER"
  # passwordless sudo so unattended deploys don't hang on a prompt
  echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEPLOY_USER"
  chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
else
  log "[3/6] Skipping deploy user (CREATE_DEPLOY_USER=$CREATE_DEPLOY_USER)."
fi

# ----- 4. Tailscale (unattended join) ----------------------------------------
log "[4/6] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

TS_ARGS=(--authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" --ssh)
[ -n "$TAILSCALE_TAGS" ] && TS_ARGS+=(--advertise-tags="$TAILSCALE_TAGS")

log "Joining tailnet as '$TAILSCALE_HOSTNAME'..."
TAILSCALE_IP=""
if tailscale up "${TS_ARGS[@]}"; then
  for _ in $(seq 1 30); do
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
    [ -n "$TAILSCALE_IP" ] && break
    sleep 1
  done
fi

if [ -z "$TAILSCALE_IP" ]; then
  log "!! Tailnet join did not confirm — aborting before the box is sealed."
  log "!! Nothing has been firewalled; this machine is unchanged and still reachable."
  log "!! Usual causes: expired or single-use auth key, or a key not authorized to"
  log "!! assign TAILSCALE_TAGS='$TAILSCALE_TAGS'. Fix the key and re-run this script."
  exit 1
fi
log "Tailscale up. IP: $TAILSCALE_IP"

# ----- 5. Harden sshd --------------------------------------------------------
# Tailscale SSH answers port 22 on the tailnet address, so sshd is not the way in.
# It is locked to nothing-works-by-default in case anything ever reaches it.
log "[5/6] Hardening sshd..."
mkdir -p /etc/ssh/sshd_config.d
SSHD_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"
cat > "$SSHD_CONF" <<'EOF'
# Managed by HQ skills/lockdown — edits will be overwritten on re-run.
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
chmod 644 "$SSHD_CONF"
# Ubuntu 24.04 uses the 'ssh' unit; older releases use 'sshd'.
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }

# ----- 6. Firewall (UFW), default deny ---------------------------------------
log "[6/6] Configuring firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing

# Tailscale direct connections
ufw allow 41641/udp comment 'tailscale'

# Administrative access: port 22 on the tailnet interface only, where tailscaled
# is listening. Nothing on the public IP.
ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh via tailnet'

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

log "Enabling UFW..."
ufw --force enable

echo ""
echo "================================================"
echo "  Lockdown complete"
echo "================================================"
echo "  Tailscale IP : $TAILSCALE_IP"
echo "  SSH (root)   : ssh root@$TAILSCALE_HOSTNAME"
[ "$CREATE_DEPLOY_USER" = "true" ] && \
echo "  SSH (deploy) : ssh $DEPLOY_USER@$TAILSCALE_HOSTNAME"
echo "  Log          : $SUMMARY_LOG"
echo "================================================"
