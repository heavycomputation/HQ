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
#   TAILSCALE_AUTHKEY     (required)  node auth key (tskey-auth-...) to join the tailnet
#   TAILSCALE_HOSTNAME    (optional)  name to register in your tailnet (default: hostname)
#   TAILSCALE_TAGS        (optional)  comma-separated ACL tags, e.g. "tag:server"
#   CREATE_DEPLOY_USER    (optional)  "true" to create a non-root sudo user (default: true)
#   DEPLOY_USER           (optional)  name of that user (default: deploy)
#   ALLOW_CLOUDFLARE_WEB  (optional)  "true" opens 80/443 to Cloudflare only (default: true)
#
# TAILSCALE_AUTHKEY is a *node* auth key, not the TAILSCALE_API_KEY from .env. The
# agent mints a fresh single-use one per box from the API key; see SKILL.md. This
# script never sees the API key — a tailnet-wide credential has no business sitting
# in cloud-init user-data, which stays readable on the box after boot.
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
  echo "[lockdown] Mint one from TAILSCALE_API_KEY: POST /api/v2/tailnet/-/keys (see SKILL.md)." >&2
  exit 1
fi

echo "================================================"
echo "  HQ lockdown — securing this box"
echo "  host: $TAILSCALE_HOSTNAME"
echo "================================================"

export DEBIAN_FRONTEND=noninteractive
# Ubuntu 22.04+ ships needrestart, which interrupts non-interactive apt runs with a
# service-restart prompt that DEBIAN_FRONTEND does not suppress. 'a' = restart
# automatically, no questions — the only safe answer with nobody at the console.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# On first boot, cloud-init and the apt-daily / unattended-upgrades timers are usually
# still holding the dpkg lock. Without this, the very first apt-get dies under set -e
# and the box is left unsecured. DPkg::Lock::Timeout handles most of it; the retry
# loop covers the rest.
apt_get() {
  local tries=0
  until apt-get -o DPkg::Lock::Timeout=60 "$@"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      log "!! 'apt-get $1' failed after $tries attempts — giving up."
      return 1
    fi
    log "'apt-get $1' failed (attempt $tries) — dpkg lock is probably still held; retrying in 15s..."
    sleep 15
  done
}

# ----- 1. Update packages ----------------------------------------------------
log "[1/6] Updating packages..."
apt_get update -y
apt_get upgrade -y
apt_get install -y curl ufw unattended-upgrades

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

# The installer starts tailscaled, but 'tailscale up' immediately after can beat the
# daemon to its socket and fail for no real reason.
for _ in $(seq 1 30); do
  systemctl is-active --quiet tailscaled && break
  sleep 1
done

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
  log "!! Usual causes: an expired or already-spent auth key, or a key not authorized"
  log "!! to assign TAILSCALE_TAGS='$TAILSCALE_TAGS' (the tag needs a tagOwners entry"
  log "!! in the tailnet policy). Mint a fresh key and re-run this script."
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
# cloud-init's PATH does not always include /usr/sbin, where sshd lives.
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if [ -x "$SSHD_BIN" ] && "$SSHD_BIN" -t; then
  # Ubuntu 24.04 uses the 'ssh' unit; older releases use 'sshd'.
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  log "!! sshd config test failed or sshd not present — skipping reload."
fi

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
  # Prefer the live lists. Both must arrive: a half-fetched list silently blocks a
  # chunk of real Cloudflare traffic, which is far harder to debug than using the
  # pinned copy wholesale.
  CF_V4="$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9.]+/[0-9]+$' || true)"
  CF_V6="$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null | grep -E '^[0-9a-fA-F:]+/[0-9]+$' || true)"
  if [ -n "$CF_V4" ] && [ -n "$CF_V6" ]; then
    CF_RANGES="$CF_V4 $CF_V6"
  else
    log "!! Could not fetch both Cloudflare lists — using pinned fallback list."
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

log "Lockdown complete on $TAILSCALE_HOSTNAME ($TAILSCALE_IP)."

echo ""
echo "================================================"
echo "  Lockdown complete"
echo "================================================"
echo "  Tailscale IP : $TAILSCALE_IP"
echo "  SSH (root)   : ssh root@$TAILSCALE_HOSTNAME"
if [ "$CREATE_DEPLOY_USER" = "true" ]; then
  echo "  SSH (deploy) : ssh $DEPLOY_USER@$TAILSCALE_HOSTNAME"
fi
echo "  Log          : $SUMMARY_LOG"
echo "================================================"
