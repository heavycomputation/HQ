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
HZ=(-H "Authorization: Bearer $HETZNER_API_TOKEN" -H 'Content-Type: application/json')
SERVER_NAME=<server-name>
```

### 0. Pick a server type that can actually be ordered

`AGENTS.md` says to ask the user about type and location one question at a time. Get the
real options first — **`server_types[].prices` lists every location a type is *priced*
in, not where it can be *ordered***. Sorting that list naively picks something that
fails to create. Availability lives in `/v1/datacenters` → `.server_types.available`:

```bash
curl -fsS "${HZ[@]}" https://api.hetzner.cloud/v1/datacenters > scratch/dcs.json
curl -fsS "${HZ[@]}" 'https://api.hetzner.cloud/v1/server_types?per_page=50' > scratch/types.json
jq -r --slurpfile dc scratch/dcs.json '
  [ $dc[0].datacenters[] as $d | ($d.server_types.available[] as $id | {dc:$d.name, loc:$d.location.name, id:$id}) ] as $pairs |
  .server_types as $types |
  [ $pairs[] | . as $p | ($types[] | select(.id==$p.id)) as $t |
    ($t.prices[] | select(.location==$p.loc)) as $pr |
    {price:($pr.price_monthly.gross|tonumber), name:$t.name, dc:$p.dc, arch:$t.architecture, cores:$t.cores, mem:$t.memory} ]
  | sort_by(.price) | .[0:8][] | [.price,.name,.dc,.arch,.cores,.mem] | @tsv' scratch/types.json
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

If the diff is empty the policy is already correct — **skip the write entirely**, which
also leaves the user's HuJSON comments untouched. Otherwise:

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
KEYJSON=$(curl -fsS "${TS[@]}" https://api.tailscale.com/api/v2/tailnet/-/keys \
  --data-binary "$(jq -n --arg d "hq lockdown $SERVER_NAME" '{
    capabilities: {devices: {create: {
      reusable: false, ephemeral: false, preauthorized: true, tags: ["tag:server"]
    }}},
    expirySeconds: 3600,
    description: $d
  }')")
AUTHKEY=$(jq -r .key <<<"$KEYJSON")
KEYID=$(jq -r .id  <<<"$KEYJSON")
```

No colon in the description — Tailscale rejects it with
`{"message":"keys: description had invalid characters"}` (HTTP 400). Keep it
alphanumeric, spaces and dashes.

Single-use and one hour by design: the copy that ends up in the box's user-data is spent
the moment the box joins, so it is worthless to anyone reading it later. Non-ephemeral so
the node survives going offline; tagged so the node never expires.

Keep `$KEYID` — if the run fails before the key is consumed it stays valid until expiry,
so revoke it rather than waiting the hour out:

```bash
curl -sS -X DELETE "${TS[@]}" "https://api.tailscale.com/api/v2/tailnet/-/keys/$KEYID"
```

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

Attach **no SSH key** — there is no key in this workflow.

```bash
curl -fsS -X POST "${HZ[@]}" https://api.hetzner.cloud/v1/servers \
  -d "$(jq -n --arg n "$SERVER_NAME" --rawfile ud scratch/user-data.sh '{
    name: $n, server_type: "<type>", image: "<image>", location: "<loc>",
    user_data: $ud
  }')" > scratch/create-response.json
jq '.server.id, .server.public_net.ipv4.ip' scratch/create-response.json
```

> **That response body contains a `root_password`** — Hetzner generates one whenever no
> SSH key is attached. Do not print it, and do not leave it on disk. Either redact it
> (`jq 'del(.root_password)'`) before saving, or delete `scratch/create-response.json`
> once you have the id and IP.

The box hardens itself on first boot and appears in your tailnet ready to use — it is
never touched before it is secured. Takes ~1–3 minutes.

### 5. Verify

**If the node has not appeared in your tailnet within ~5 minutes, the run failed.** Go
straight to break-glass below and read the log; do not keep waiting.

```bash
tailscale status | grep "$SERVER_NAME"        # run locally — the box has no jq

ssh deploy@$SERVER_NAME 'whoami && sudo -n true && echo sudo ok'
ssh deploy@$SERVER_NAME 'sudo ufw status verbose'          # default deny, tailscale0:22, CF rules
ssh deploy@$SERVER_NAME 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin)"'
ssh root@$SERVER_NAME   'cat /var/log/hq-lockdown.log'     # full run log, incl. any warnings
```

Confirm the public surface is closed. Do **not** use `nc -w` — macOS `nc` ignores it on
a filtered port and hangs for minutes:

```bash
probe() {  # exit 28 = blocked (what we want); 0 = open; 7 = refused
  curl -sS --connect-timeout 8 "telnet://$1:$2" </dev/null >/dev/null 2>&1
  case $? in 28) echo "  $2: blocked (ok)";; 0) echo "  $2: OPEN — investigate";;
             7) echo "  $2: refused (reachable but nothing listening)";;
             *) echo "  $2: curl exit $? — check manually";; esac
}
for p in 22 80 443; do probe <public-ip> $p; done
rm -f scratch/user-data.sh scratch/create-response.json
```

**On a box that already exists**, skip steps 3–4: get a root shell (Tailscale SSH if it
is already on your tailnet, otherwise break-glass), export the same vars, and run the
script directly. Re-running on a live box is safe and preserves access, including with
an already-spent auth key.

## Break-glass — the run failed and there is no tailnet

The Hetzner console is the documented last resort, but it is a browser VNC session and
you cannot use it. This path is fully API-driven:

```bash
curl -fsS -X POST "${HZ[@]}" \
  https://api.hetzner.cloud/v1/servers/<id>/actions/reset_password | jq -r .root_password
```

Then a password SSH session — macOS ships `expect`; `sshpass` is not installed. Read
**`/var/log/cloud-init-output.log`**, and `/var/log/hq-lockdown.log` (the script mirrors
all subprocess output into it, so the real error should be there).

Two things to say to the user when you do this: it is a **temporary** deviation from the
no-keys/no-passwords model, so the box must be re-locked or destroyed afterwards; and
the reset password must not be written to disk or into any repo file.

## Decommissioning

Destroying the Hetzner box leaves its tailnet device behind forever. Do both, or stale
nodes accumulate in the tailnet:

```bash
curl -sS -X DELETE "${HZ[@]}" https://api.hetzner.cloud/v1/servers/<id>

DEVID=$(curl -fsS "${TS[@]}" https://api.tailscale.com/api/v2/tailnet/-/devices \
  | jq -r --arg n "$SERVER_NAME" '.devices[] | select(.hostname == $n) | .id')
curl -sS -X DELETE "${TS[@]}" "https://api.tailscale.com/api/v2/device/$DEVID"
```

Also revoke the auth key if the run failed before it was consumed (step 2), and delete
`servers/<project>/` if the box was a throwaway.

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

The order is deliberate: **get reachable, get sealed, then everything else.** A fresh
Hetzner box boots with every port open and sshd accepting passwords, so a failure that
leaves it in that state is the worst outcome.

1. `apt update`, installs just `curl` and `ufw`.
2. Installs Tailscale and joins the tailnet with `--ssh`. **Aborts here if the join does
   not confirm**, before anything has been changed — the box is left untouched and still
   reachable rather than sealed with no way in.
3. UFW default-deny, tailnet-only port 22, `41641/udp`, enabled immediately. From here
   the box is both reachable and closed.
4. Creates the non-root `deploy` user with passwordless sudo — no key, no password.
5. Hardens `sshd`, then **verifies the effective config** with `sshd -T` rather than
   assuming the drop-in won.
6. Cloudflare-only web ports.
7. `apt upgrade` and unattended security upgrades — last, because it is the slowest and
   most failure-prone step and the security posture is already final by then.

Every step is idempotent; re-running is safe. Any unexpected failure is trapped, logged
with its line number, and reported — including whether UFW got enabled, so you know
whether the box is exposed. All subprocess output is mirrored into
`/var/log/hq-lockdown.log`.

## Gotchas

- **`useradd`, never `adduser`.** `adduser --gecos ""` shells out to `/bin/chfn`, and PAM
  refuses chfn while the caller's password is expired. Hetzner force-expires root's
  password on every box created without an SSH key — which is every box here — so
  `adduser` fails 100% of the time on a real first boot. Worse, it fails *after*
  partially creating the account, so a later `id deploy` succeeds and hides the bug on a
  manual re-run.
- **sshd honours the FIRST value for a keyword**, and reads `sshd_config.d/*.conf` in
  sort order. cloud-init ships `50-cloud-init.conf` with `PasswordAuthentication yes`,
  so the hardening drop-in must sort before it — hence `00-hq-hardening.conf`. Always
  check `sshd -T`, never just that the file was written.
- **`sshd -t`/`-T` need `/run/sshd` to exist.** systemd creates it from
  `RuntimeDirectory=sshd` only when `ssh.service` starts, and Ubuntu 24.04
  socket-activates sshd — so on a sealed fresh box, where nothing ever connects, it
  does not exist and both calls fail with *Missing privilege separation directory*.
  The script does `mkdir -p /run/sshd` first. If you check by hand on a fresh box, do
  the same or you will get a false negative.
- **Tag your servers.** An untagged node inherits the key creator's identity and the
  default ~180-day key expiry; when it expires the box silently drops off the tailnet
  and the only way back is the Hetzner console. This is the nastiest slow-burn failure
  in the workflow — the box works fine for six months and then vanishes.
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
- **The box has no `jq`.** Run `tailscale status --json | jq` locally, or use
  `tailscale status --self --peers=false` on the box.
- **Cloudflare ranges are fetched live.** Both lists must arrive or the script uses its
  pinned fallback wholesale — a half-fetched list would silently block real Cloudflare
  traffic. If the fallback is used it shows in the run summary's warnings; refresh
  against <https://www.cloudflare.com/ips/>.
- **Tailscale API keys expire** (90 days max). A policy or key call failing with 401 is
  usually just an expired `TAILSCALE_API_KEY`.
- After running, record in `servers/<project>/AGENTS.md` that the box was secured with
  `skills/lockdown` and note any non-default config used — unless it is a throwaway, in
  which case skip the folder and destroy the box per **Decommissioning**.
