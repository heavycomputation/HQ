---
name: lockdown
description: >-
  Lock down and secure a fresh Ubuntu/Debian VPS before any application work begins.
  Applies a hardening baseline: unattended security upgrades, a
  non-root sudo deploy user, UFW default-deny, SSH restricted to your Tailscale
  tailnet, and web ports open only to Cloudflare. Use when the user wants to secure,
  harden, or lock down a new or existing server / box / VPS, or immediately after
  provisioning a Hetzner box. Lockout-safe: public SSH is only closed after Tailscale
  is confirmed up.
license: MIT
compatibility: >-
  Targets Ubuntu 22.04+/Debian 12+ with apt and systemd. Needs root on the box and a
  Tailscale auth key. Cloudflare is optional.
---

# Lockdown — secure a fresh box

This skill is a single self-contained script, `scripts/lockdown.sh` — copy it to a box and run it.

The end state: a box with a public IP but almost no public attack surface. SSH is
reachable only over your tailnet, web ports only from Cloudflare, everything else
denied.

## When to use this skill

- Right after provisioning a new Hetzner box, before installing anything app-specific.
- "Harden / secure / lock down this server."
- On an existing box that was never secured (the script is safe to re-run).

## Prerequisites

- Root SSH access to the box (fresh Hetzner boxes give you `root` with your master key).
- `TAILSCALE_AUTHKEY` in the repo-root `.env` — Tailscale admin → Settings → Keys.
  Generate a **reusable, non-ephemeral** key so the node persists in your tailnet.

## Run it

From HQ on your local machine, with `.env` populated:

```bash
set -a; source .env; set +a

scp skills/lockdown/scripts/lockdown.sh root@<public-ip>:/tmp/
ssh root@<public-ip> "
  export TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY' TAILSCALE_HOSTNAME='<server-name>'
  bash /tmp/lockdown.sh
"
```

Takes ~1–3 minutes, mostly `apt upgrade`.

**The SSH session will drop at the very end.** Enabling UFW cuts connections on the
public IP — that is the lockdown working. Everything is already done by that point.
Reconnect over the tailnet:

```bash
ssh deploy@<server-name>
```

To run it truly unattended (recommended for slow links, so a dropped session can't
interrupt the tail of the script), detach it and read the log after:

```bash
ssh root@<public-ip> "... setsid nohup bash /tmp/lockdown.sh > /var/log/hq-lockdown-run.log 2>&1 &"
# then, over the tailnet:
ssh root@<server-name> 'cat /var/log/hq-lockdown-run.log'
```

It also runs as cloud-init user-data at first boot: prepend a shebang and `export` the
config vars, then append the body of the script.

## Configuration

All config is environment variables — nothing is read from files.

| Var | Default | Purpose |
|-----|---------|---------|
| `TAILSCALE_AUTHKEY` | — | Reusable, persistent Tailscale auth key. Without it the script skips the tailnet join and **leaves public SSH open**. |
| `TAILSCALE_HOSTNAME` | `$(hostname)` | Name registered in your tailnet. Pass the server name. |
| `CREATE_DEPLOY_USER` | `true` | Create a non-root sudo user. |
| `DEPLOY_USER` | `deploy` | Name of that user. |
| `DISABLE_ROOT_SSH` | `false` | `true` → `PermitRootLogin no`. Only set this once you have confirmed `deploy` access works. |
| `ALLOW_CLOUDFLARE_WEB` | `true` | Open 80/443 to Cloudflare ranges only. Set `false` on a box with no web app — ports stay closed. |

## What it does

1. `apt update && upgrade`, installs `curl`, `ufw`, `unattended-upgrades`.
2. Enables unattended security upgrades.
3. Creates the non-root `deploy` user with passwordless sudo, copying root's
   `authorized_keys` so your master key works for it too.
4. Installs Tailscale and joins the tailnet with `--ssh`, waiting up to 30s to confirm.
5. Hardens `sshd`: key-only auth, no passwords, `PermitRootLogin prohibit-password`.
6. Configures UFW default-deny, Cloudflare-only web ports, tailnet-only SSH, enables it.

Step 5 runs before step 6 deliberately — enabling the firewall drops a public-IP SSH
session, so sshd must already be hardened by then.

Full detail, exact rules, and rationale: [references/security-model.md](references/security-model.md).
Read it before changing any firewall or SSH rule on a live box.

## Gotchas

- **Lockout-safe by design.** If Tailscale does not come up, public SSH (port 22) is
  left **open** rather than locking you out, and the script logs a loud warning. Fix
  Tailscale, confirm tailnet access, then close it by hand: `ufw delete allow 22/tcp`.
- **Verify before disabling root SSH.** Log in as `deploy` over the tailnet first;
  only then re-run with `DISABLE_ROOT_SSH=true`.
- **Cloudflare ranges are fetched live** from `cloudflare.com/ips-v4`/`-v6`, with a
  pinned fallback list if the fetch fails. If the fallback is used, refresh the rules
  later against <https://www.cloudflare.com/ips/>.
- **Run summary** is appended to `/var/log/hq-lockdown.log` on the box.
- After running, record in `servers/<project>/AGENTS.md` that the box was secured with
  `skills/lockdown` and note any non-default config used.
