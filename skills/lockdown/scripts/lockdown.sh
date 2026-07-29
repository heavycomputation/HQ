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
# ORDERING IS DELIBERATE. A fresh Hetzner box created without an SSH key boots with
# every port open, sshd accepting passwords, and a Hetzner-set root password. Every
# second spent in that state is exposure, and a failure that leaves the box there is
# the worst outcome. So the sequence is: get reachable (Tailscale), get sealed (UFW),
# then do everything else. The slow, failure-prone `apt upgrade` runs last, once the
# box's security posture is already final. If a late step dies, the box is still
# locked down and you can still get in to fix it.
#
# SAFETY: the script aborts if the tailnet join does not confirm, before anything has
# been changed — leaving the box exactly as it was rather than sealing it with no way
# back in. Break-glass is the Hetzner console, or an API-driven root password reset
# (see SKILL.md). Any unexpected failure is trapped, logged loudly, and reported.
#
# Re-runnable: every step is idempotent.

set -Eeuo pipefail

# ----- config with defaults --------------------------------------------------
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"
TAILSCALE_TAGS="${TAILSCALE_TAGS:-}"
CREATE_DEPLOY_USER="${CREATE_DEPLOY_USER:-true}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
ALLOW_CLOUDFLARE_WEB="${ALLOW_CLOUDFLARE_WEB:-true}"

SUMMARY_LOG="/var/log/hq-lockdown.log"

if [ "$(id -u)" -ne 0 ]; then
  echo "[lockdown] must run as root." >&2
  exit 1
fi

# Mirror everything — including apt/useradd/tailscale output — into the run log.
# Without this the log holds only our own banners, and the actual cause of a failure
# is stranded in /var/log/cloud-init-output.log where nobody thinks to look.
mkdir -p "$(dirname "$SUMMARY_LOG")"
exec > >(tee -a "$SUMMARY_LOG") 2>&1

log()  { echo "[lockdown] $*"; }
WARNINGS=()
warn() { WARNINGS+=("$*"); echo "[lockdown] !! $*"; }

# Report where we died. Without this a failure is silent: cloud-init exits, the box
# looks "running" in the console, and the only symptom is a tailnet node that never
# appears.
on_err() {
  local rc=$? line=$1
  echo ""
  echo "[lockdown] !! FAILED at line $line (exit $rc) — THIS BOX IS NOT FULLY SECURED."
  echo "[lockdown] !! Run log: $SUMMARY_LOG"
  echo "[lockdown] !! cloud-init output: /var/log/cloud-init-output.log"
  if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "[lockdown] !! UFW is NOT active — every port is open on the public IP."
    echo "[lockdown] !! Treat this box as exposed: fix and re-run, or destroy it."
  fi
  exit "$rc"
}
trap 'on_err $LINENO' ERR

echo "================================================"
echo "  HQ lockdown — securing this box"
echo "  host: $TAILSCALE_HOSTNAME"
echo "  time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================"

if [ -z "$TAILSCALE_AUTHKEY" ]; then
  log "TAILSCALE_AUTHKEY is required — it is the only way back into this box."
  log "Mint one from TAILSCALE_API_KEY: POST /api/v2/tailnet/-/keys (see SKILL.md)."
  exit 1
fi

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
      log "'apt-get $1' failed after $tries attempts — giving up."
      return 1
    fi
    log "'apt-get $1' failed (attempt $tries) — dpkg lock is probably still held; retrying in 15s..."
    sleep 15
  done
}

# ----- 1. Minimum packages needed to get reachable and sealed ----------------
log "[1/7] Installing base packages (curl, ufw)..."
apt_get update -y
apt_get install -y curl ufw

# ----- 2. Tailscale (unattended join) ----------------------------------------
# First real step, on purpose: until this succeeds there is no way into the box
# except the console, so nothing else is worth doing.
log "[2/7] Installing Tailscale..."
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
  trap - ERR
  log "Tailnet join did not confirm — aborting before the box is sealed."
  log "Nothing has been firewalled; this machine is unchanged and still reachable."
  log "Usual causes: an expired or already-spent auth key, or a key not authorized"
  log "to assign TAILSCALE_TAGS='$TAILSCALE_TAGS' (the tag needs a tagOwners entry"
  log "in the tailnet policy). Mint a fresh key and re-run this script."
  exit 1
fi
log "Tailscale up. IP: $TAILSCALE_IP"

# ----- 3. Seal the box -------------------------------------------------------
# Done immediately after the join, not at the end: from here on the box is both
# reachable and closed, so any later failure is recoverable rather than exposing it.
log "[3/7] Sealing the public surface (UFW default-deny)..."
ufw default deny incoming
ufw default allow outgoing

# Tailscale direct connections
ufw allow 41641/udp comment 'tailscale'

# Administrative access: port 22 on the tailnet interface only, where tailscaled
# is listening. Nothing on the public IP.
ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh via tailnet'

ufw --force enable
log "UFW active — public surface closed."

# ----- 4. Non-root deploy user -----------------------------------------------
# No keys and no password: you reach this account through Tailscale SSH, which
# authorizes you by tailnet identity. Grant it in your SSH policy via
# "users": ["deploy"].
if [ "$CREATE_DEPLOY_USER" = "true" ]; then
  log "[4/7] Creating deploy user '$DEPLOY_USER'..."
  if ! id "$DEPLOY_USER" &>/dev/null; then
    # useradd, NOT `adduser --gecos ""`. adduser shells out to /bin/chfn to set the
    # GECOS field, and PAM refuses chfn while the caller's password is expired.
    # Hetzner force-expires root's password on any box created without an SSH key,
    # which is every box in this workflow — so adduser fails 100% of the time on a
    # real first boot. It also fails *after* partially creating the account, so a
    # later `id deploy` succeeds and hides the bug on a manual re-run.
    useradd --create-home --shell /bin/bash "$DEPLOY_USER"
  fi
  # No password should ever authenticate this account.
  passwd --lock "$DEPLOY_USER" >/dev/null
  usermod -aG sudo "$DEPLOY_USER"
  # passwordless sudo so unattended deploys don't hang on a prompt
  echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEPLOY_USER"
  chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
else
  log "[4/7] Skipping deploy user (CREATE_DEPLOY_USER=$CREATE_DEPLOY_USER)."
fi

# ----- 5. Harden sshd --------------------------------------------------------
# Tailscale SSH answers port 22 on the tailnet address, so sshd is not the way in.
# It is locked to nothing-works-by-default in case anything ever reaches it.
log "[5/7] Hardening sshd..."
mkdir -p /etc/ssh/sshd_config.d
# 00-, not 99-: sshd includes sshd_config.d/*.conf in sort order and honours the
# FIRST value it sees for a keyword. cloud-init ships 50-cloud-init.conf containing
# 'PasswordAuthentication yes', which silently beat the old 99- file — the drop-in
# was written, looked right, and did nothing.
rm -f /etc/ssh/sshd_config.d/99-hardening.conf
SSHD_CONF="/etc/ssh/sshd_config.d/00-hq-hardening.conf"
cat > "$SSHD_CONF" <<'EOF'
# Managed by HQ skills/lockdown — edits will be overwritten on re-run.
# Must sort before cloud-init's 50-cloud-init.conf: first value wins in sshd.
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

  # Verify the *effective* config rather than trusting that writing a file worked.
  SSHD_EFFECTIVE="$("$SSHD_BIN" -T 2>/dev/null || true)"
  if [ -z "$SSHD_EFFECTIVE" ]; then
    warn "Could not read effective sshd config ('sshd -T' produced nothing) — hardening unverified."
  else
    for expect in "passwordauthentication no" "permitrootlogin no"; do
      key="${expect%% *}"; want="${expect##* }"
      got="$(printf '%s\n' "$SSHD_EFFECTIVE" | awk -v k="$key" '$1 == k { print $2; exit }')"
      if [ "$got" = "$want" ]; then
        log "sshd: $key = $got (ok)"
      else
        warn "sshd: $key is '${got:-unset}', expected '$want' — another drop-in in /etc/ssh/sshd_config.d/ is winning. Check sort order."
      fi
    done
  fi
else
  warn "sshd config test failed or sshd not present — skipping reload and verification."
fi

# ----- 6. Cloudflare web ports -----------------------------------------------
if [ "$ALLOW_CLOUDFLARE_WEB" = "true" ]; then
  log "[6/7] Allowing 80/443 from Cloudflare ranges only..."
  # Prefer the live lists. Both must arrive: a half-fetched list silently blocks a
  # chunk of real Cloudflare traffic, which is far harder to debug than using the
  # pinned copy wholesale.
  CF_V4="$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9.]+/[0-9]+$' || true)"
  CF_V6="$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null | grep -E '^[0-9a-fA-F:]+/[0-9]+$' || true)"
  if [ -n "$CF_V4" ] && [ -n "$CF_V6" ]; then
    CF_RANGES="$CF_V4 $CF_V6"
  else
    warn "Could not fetch both Cloudflare lists — using pinned fallback list. Refresh later against https://www.cloudflare.com/ips/"
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
  log "[6/7] Skipping Cloudflare web rules (ALLOW_CLOUDFLARE_WEB=$ALLOW_CLOUDFLARE_WEB)."
  log "Ports 80/443 stay closed — open them yourself when you deploy a web app."
fi

# ----- 7. Upgrades -----------------------------------------------------------
# Last on purpose: the slowest and most failure-prone step, run only once the box's
# security posture is already final.
log "[7/7] Upgrading packages and enabling unattended security upgrades..."
apt_get upgrade -y
apt_get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

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
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "------------------------------------------------"
  echo "  ${#WARNINGS[@]} warning(s) — box is secured but review these:"
  for w in "${WARNINGS[@]}"; do echo "    - $w"; done
fi
echo "================================================"
