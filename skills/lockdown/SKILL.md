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
  Targets Ubuntu 22.04+/Debian 12+ with apt and systemd. Needs HETZNER_API_TOKEN and
  TAILSCALE_API_KEY in the repo-root .env, plus curl and jq locally. Cloudflare is
  optional.
---

# Lockdown — secure a fresh box

The end state: a box with a public IP but almost no public attack surface. Port 22 is
answered by `tailscaled` on the tailnet address only, web ports accept only Cloudflare,
everything else is denied. There are no SSH keys and no passwords in the baseline —
access is your tailnet identity, governed by your Tailscale SSH policy.

You do all of it from the two API credentials in `.env`. The user should never have to
create a Tailscale auth key or hand-edit a policy file — that is your job.

## When to use this skill

- Right after provisioning a new Hetzner box, before installing anything app-specific.
- "Harden / secure / lock down this server."
- On an existing box that was never secured (the script is safe to re-run).

## The two credentials

| `.env` var | What it is | Used for |
|---|---|---|
| `HETZNER_API_TOKEN` | Hetzner Cloud API token | Creating the server with user-data |
| `TAILSCALE_API_KEY` | `tskey-api-…` REST token | Reading/updating the tailnet policy, minting auth keys |

`TAILSCALE_API_KEY` is **not** what a machine uses to join the tailnet. That needs a
*node auth key* (`tskey-auth-…`), which you mint per box from the API key in step 2.
Never put the API key itself into user-data — it is tailnet-wide, and user-data stays
readable on the box after boot.

Also required locally: `curl`, `jq`, and your own machine logged into the tailnet
(that is how you reach the box afterwards).

## Provisioning flow

```bash
set -a; source .env; set +a
mkdir -p scratch                      # gitignored
TS=(-u "$TAILSCALE_API_KEY:" -H 'Content-Type: application/json')
SERVER_NAME=<server-name>
```

### 1. Ensure the tailnet policy allows tagged servers

Do this **first**. Two things must be true or the box will boot and be unreachable:
`tag:server` must have a `tagOwners` entry (otherwise you cannot even mint a tagged
key), and an SSH rule must grant `deploy` on `tag:server` with `"action": "accept"`.

Back up the policy verbatim as HuJSON, and capture the ETag:

```bash
curl -fsS "${TS[@]}" -H 'Accept: application/hujson' -D scratch/acl-headers.txt \
  https://api.tailscale.com/api/v2/tailnet/-/acl > scratch/acl-backup.hujson
ETAG=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' scratch/acl-headers.txt | tr -d '\r')
```

Fetch it again as strict JSON and merge additively — never replace wholesale:

```bash
curl -fsS "${TS[@]}" -H 'Accept: application/json' \
  https://api.tailscale.com/api/v2/tailnet/-/acl > scratch/acl.json

jq '
  .tagOwners //= {} |
  .tagOwners["tag:server"] //= ["autogroup:admin"] |
  .ssh //= [] |
  if any(.ssh[]?; .action == "accept"
                  and (.dst // [] | index("tag:server"))
                  and (.users // [] | index("deploy")))
  then .
  else .ssh += [{
    action: "accept",
    src:    ["autogroup:member"],
    dst:    ["tag:server"],
    users:  ["deploy", "root"]
  }] end
' scratch/acl.json > scratch/acl-new.json

diff <(jq -S . scratch/acl.json) <(jq -S . scratch/acl-new.json) || true
```

If the diff is empty the policy is already correct — skip the write. Otherwise:

```bash
curl -fsS -X POST "${TS[@]}" -H "If-Match: $ETAG" \
  --data-binary @scratch/acl-new.json \
  https://api.tailscale.com/api/v2/tailnet/-/acl
```

`If-Match` makes a concurrent edit fail with **412** instead of silently clobbering it.
On 412, re-fetch and redo the merge — do not retry without the ETag. On a tailnet whose
policy has never been touched you can pass `If-Match: "ts-default"`.

> **Tell the user before you POST:** this round-trips their policy through strict JSON,
> so any comments or trailing commas in their HuJSON are lost. `scratch/acl-backup.hujson`
> holds the original. If they have a commented policy they care about, edit the HuJSON
> textually instead — insert the same two fragments by hand and POST that.

### 2. Mint a single-use auth key for this box

```bash
AUTHKEY=$(curl -fsS "${TS[@]}" https://api.tailscale.com/api/v2/tailnet/-/keys \
  --data-binary "$(jq -n --arg d "hq lockdown: $SERVER_NAME" '{
    capabilities: {devices: {create: {
      reusable: false, ephemeral: false, preauthorized: true, tags: ["tag:server"]
    }}},
    expirySeconds: 3600,
    description: $d
  }')" | jq -r .key)
```

Single-use and one hour by design: the copy that ends up in the box's user-data is spent
the moment the box joins, so it is worthless to anyone reading it later. If a run fails,
mint a fresh one — it is one call. Non-ephemeral so the node survives going offline;
tagged so the node never expires.

### 3. Build the user-data

```bash
{
  echo '#!/usr/bin/env bash'
  echo "export TAILSCALE_AUTHKEY='$AUTHKEY'"
  echo "export TAILSCALE_HOSTNAME='$SERVER_NAME'"
  echo "export TAILSCALE_TAGS='tag:server'"
  tail -n +2 skills/lockdown/scripts/lockdown.sh
} > scratch/user-data.sh
```

### 4. Create the server

Per `AGENTS.md`, ask the user for type/image/location one question at a time rather than
assuming. Attach **no SSH key** — there is no key in this workflow.

```bash
curl -fsS -X POST https://api.hetzner.cloud/v1/servers \
  -H "Authorization: Bearer $HETZNER_API_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "$SERVER_NAME" --rawfile ud scratch/user-data.sh '{
    name: $n, server_type: "<type>", image: "<image>", location: "<loc>",
    user_data: $ud
  }')"
```

The box hardens itself on first boot and appears in your tailnet ready to use — it is
never touched before it is secured. Takes ~1–3 minutes, mostly `apt upgrade`.

### 5. Verify, then clean up

```bash
ssh deploy@$SERVER_NAME 'whoami && sudo -n true && echo sudo ok'
ssh deploy@$SERVER_NAME 'sudo ufw status verbose'      # default deny, tailscale0:22, CF rules
ssh root@$SERVER_NAME  'cat /var/log/hq-lockdown.log'  # full run log
nc -vz -w 5 <public-ip> 22                             # from off-tailnet: must time out

rm -f scratch/user-data.sh
```

**On a box that already exists**, skip steps 3–4: get a root shell (Tailscale SSH if it
is already on your tailnet, otherwise the Hetzner console), export the same vars, and run
the script directly.

## Configuration

All script config is environment variables — nothing is read from files.

| Var | Default | Purpose |
|-----|---------|---------|
| `TAILSCALE_AUTHKEY` | — | **Required.** Node auth key from step 2. The script exits if it is missing. |
| `TAILSCALE_HOSTNAME` | `$(hostname)` | Name registered in your tailnet. Pass the server name. |
| `TAILSCALE_TAGS` | — | ACL tags, e.g. `tag:server`. Tagged nodes never expire — strongly recommended. |
| `CREATE_DEPLOY_USER` | `true` | Create a non-root sudo user. |
| `DEPLOY_USER` | `deploy` | Name of that user. |
| `ALLOW_CLOUDFLARE_WEB` | `true` | Open 80/443 to Cloudflare ranges only. Set `false` on a box with no web app — ports stay closed. |

## What the script does

1. `apt update && upgrade`, installs `curl`, `ufw`, `unattended-upgrades`. Retries
   through the dpkg lock that cloud-init and `apt-daily` hold on first boot.
2. Enables unattended security upgrades.
3. Creates the non-root `deploy` user with passwordless sudo — no key, no password.
4. Installs Tailscale and joins the tailnet with `--ssh`, waiting up to 30s to confirm.
   **Aborts here if the join does not confirm**, leaving the box untouched and still
   reachable rather than sealing it with no way in.
5. Hardens `sshd`: no passwords, no root login.
6. Configures UFW default-deny, tailnet-only port 22, Cloudflare-only web ports.

Every step is idempotent; re-running is safe.

## Gotchas

- **`"action": "accept"`, never `"check"`.** The stock policy's SSH rule is `check`,
  which forces an interactive browser re-auth and will stall an unattended agent
  mid-run. The stock rule also targets `autogroup:self`, which does not match a tagged
  node — a tagged box needs its own rule.
- **List `root` explicitly** in the SSH rule's `users` if you want `ssh root@<host>` for
  reading the run log. `autogroup:nonroot` excludes it.
- **`PermitRootLogin no` does not block Tailscale SSH.** Tailscale SSH is a separate
  server inside `tailscaled` and ignores `sshd_config`, so root over the tailnet still
  works while sshd stays locked.
- **A restrictive ACL still applies.** The default `src: ["*"] / dst: ["*:*"]` rule
  covers tagged nodes, but a tailnet with a narrowed `acls` block may also need
  `tag:server` added there. The SSH rule alone is not enough.
- **Tag your servers.** An untagged node inherits the key creator's identity and the
  default ~180-day key expiry; when it expires the box silently drops off the tailnet
  and the only way back is the Hetzner console.
- **Cloudflare ranges are fetched live** from `cloudflare.com/ips-v4`/`-v6`. Both lists
  must arrive or the script uses its pinned fallback wholesale — a half-fetched list
  would silently block real Cloudflare traffic. If the fallback is used, refresh later
  against <https://www.cloudflare.com/ips/>.
- **Tailscale API keys expire** (90 days max). A failing policy or key call with 401 is
  usually just an expired `TAILSCALE_API_KEY`.
- **Break-glass is the Hetzner Cloud Console** (VNC, or Rescue mode). There is no key to
  fall back on, by design.
- After running, record in `servers/<project>/AGENTS.md` that the box was secured with
  `skills/lockdown` and note any non-default config used.
