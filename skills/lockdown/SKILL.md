---
name: lockdown
description: >-
  Lock down and secure a fresh Ubuntu/Debian VPS before any application work begins.
  Applies a hardening baseline: unattended security upgrades, a non-root sudo deploy
  user, UFW default-deny, administrative access over Tailscale SSH only, and web ports
  open only to Cloudflare. Use when the user wants to secure, harden, or lock down a
  new or existing server / box / VPS, or immediately after provisioning a Hetzner box.
license: MIT
compatibility: >-
  Targets Ubuntu 22.04+/Debian 12+ with apt and systemd. Needs root on the box and a
  Tailscale auth key. Cloudflare is optional.
---

# Lockdown — secure a fresh box

This skill is a single self-contained script, `scripts/lockdown.sh` — run it on a box
as root.

The end state: a box with a public IP but almost no public attack surface. Port 22 is
answered by `tailscaled` on the tailnet address only, web ports accept only Cloudflare,
everything else is denied. There are no SSH keys and no passwords in the baseline —
access is your tailnet identity, governed by your Tailscale SSH policy.

## When to use this skill

- Right after provisioning a new Hetzner box, before installing anything app-specific.
- "Harden / secure / lock down this server."
- On an existing box that was never secured (the script is safe to re-run).

## Prerequisites

- `TAILSCALE_AUTHKEY` in the repo-root `.env` — Tailscale admin → Settings → Keys.
  Generate a **reusable, non-ephemeral** key, tagged `tag:server`.
- An SSH policy in your tailnet that grants access to those servers. If you have not
  set one up, do that first: [references/tailscale-ssh.md](references/tailscale-ssh.md).
  A box that joins the tailnet with no matching policy rule is a box you cannot log
  into.

## Run it

**The default path is cloud-init user-data at server creation.** The box hardens itself
on first boot and appears in your tailnet ready to use — you never touch it beforehand,
so it never needs a key.

Build the user-data file:

```bash
set -a; source .env; set +a

{
  echo '#!/usr/bin/env bash'
  echo "export TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY'"
  echo "export TAILSCALE_HOSTNAME='<server-name>'"
  echo "export TAILSCALE_TAGS='tag:server'"
  tail -n +2 skills/lockdown/scripts/lockdown.sh
} > /tmp/hq-user-data.sh
```

Then pass it at create time — `--user-data-from-file` with the `hcloud` CLI, or the
`user_data` field on `POST /v1/servers` in the Hetzner API.

Takes ~1–3 minutes after boot, mostly `apt upgrade`. When it lands:

```bash
ssh deploy@<server-name>
```

Read the run log if anything looks off:

```bash
ssh root@<server-name> 'cat /var/log/hq-lockdown.log'
```

**On a box that already exists**, get a root shell — Tailscale SSH if it is already on
your tailnet, otherwise the Hetzner console — and run the script the same way, with the
config vars exported.

## Configuration

All config is environment variables — nothing is read from files.

| Var | Default | Purpose |
|-----|---------|---------|
| `TAILSCALE_AUTHKEY` | — | **Required.** Reusable, non-ephemeral auth key. The script exits if it is missing. |
| `TAILSCALE_HOSTNAME` | `$(hostname)` | Name registered in your tailnet. Pass the server name. |
| `TAILSCALE_TAGS` | — | ACL tags, e.g. `tag:server`. Tagged nodes never expire — strongly recommended. |
| `CREATE_DEPLOY_USER` | `true` | Create a non-root sudo user. |
| `DEPLOY_USER` | `deploy` | Name of that user. |
| `ALLOW_CLOUDFLARE_WEB` | `true` | Open 80/443 to Cloudflare ranges only. Set `false` on a box with no web app — ports stay closed. |

## What it does

1. `apt update && upgrade`, installs `curl`, `ufw`, `unattended-upgrades`.
2. Enables unattended security upgrades.
3. Creates the non-root `deploy` user with passwordless sudo — no key, no password.
4. Installs Tailscale and joins the tailnet with `--ssh`, waiting up to 30s to confirm.
   **Aborts here if the join does not confirm**, leaving the box untouched.
5. Hardens `sshd`: no passwords, no root login.
6. Configures UFW default-deny, tailnet-only port 22, Cloudflare-only web ports.

Full detail, exact rules, and rationale: [references/security-model.md](references/security-model.md).
Read it before changing any firewall or SSH rule on a live box.

## Gotchas

- **Grant `deploy` in your SSH policy.** The policy's `users` list must include
  `deploy` (or `autogroup:nonroot`), or the account exists with no way to reach it.
- **Use `"action": "accept"`, not `"check"`.** `check` forces an interactive browser
  re-auth and will stall an unattended agent mid-run. See
  [references/tailscale-ssh.md](references/tailscale-ssh.md).
- **Tag your servers.** An untagged node inherits the key creator's identity and the
  default ~180-day key expiry; when it expires the box silently drops off the tailnet
  and the only way back is the Hetzner console.
- **Cloudflare ranges are fetched live** from `cloudflare.com/ips-v4`/`-v6`, with a
  pinned fallback list if the fetch fails. If the fallback is used, refresh the rules
  later against <https://www.cloudflare.com/ips/>.
- **Run summary** is appended to `/var/log/hq-lockdown.log` on the box.
- After running, record in `servers/<project>/AGENTS.md` that the box was secured with
  `skills/lockdown` and note any non-default config used.
