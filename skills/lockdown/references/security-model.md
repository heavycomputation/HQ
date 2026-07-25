# Security model — the lockdown baseline

The detailed reference for what `scripts/lockdown.sh` does and why. Read this before
changing any firewall or SSH rule on a locked-down box.

## Threat posture

The box has a public IPv4/IPv6 but presents **almost no public attack surface**:

- **SSH is not reachable from the internet.** Port 22 is bound to the `tailscale0`
  interface only — reachable exclusively from devices in your tailnet.
- **Web is reachable only from Cloudflare.** Ports 80/443 accept traffic only from
  Cloudflare's published ranges, so the origin sits behind Cloudflare and the origin IP
  need never appear in DNS. Optional — set `ALLOW_CLOUDFLARE_WEB=false` on a box with
  no web app and both ports stay closed.
- **Everything else is denied** by UFW's default-deny-incoming policy.

Tailscale is doing the heavy lifting here: it is the only ingress path for
administration. That makes the auth key and your tailnet ACLs the things worth
protecting. Use a reusable, non-ephemeral key so the node persists, and rotate it if it
ever leaks — a leaked key lets someone add a node to your tailnet, not reach this box's
SSH directly, but it is still a serious exposure.

## Configuration

| Var | Default | Purpose |
|-----|---------|---------|
| `TAILSCALE_AUTHKEY` | — | Reusable/persistent Tailscale auth key. Empty → no join, public SSH stays open. |
| `TAILSCALE_HOSTNAME` | `$(hostname)` | Hostname registered in your tailnet. |
| `CREATE_DEPLOY_USER` | `true` | Create a non-root sudo user. |
| `DEPLOY_USER` | `deploy` | Name of that user. |
| `DISABLE_ROOT_SSH` | `false` | `true` → `PermitRootLogin no`. |
| `ALLOW_CLOUDFLARE_WEB` | `true` | Open 80/443 to Cloudflare ranges only. |

## Step by step

1. **System update** — `apt-get update && upgrade`, then install `curl`, `ufw`,
   `unattended-upgrades`.

2. **Unattended security upgrades** — writes `/etc/apt/apt.conf.d/20auto-upgrades` and
   enables the `unattended-upgrades` unit, so security patches apply automatically
   without anyone logging in.

3. **Non-root deploy user** — creates `deploy` (password login disabled) in the `sudo`
   group with a `NOPASSWD` sudoers drop-in, so unattended deploys never hang on a
   password prompt. Root's `authorized_keys` is copied to the user, so the same master
   SSH key logs in as `deploy`. If root has no `authorized_keys` the script warns and
   continues — Tailscale SSH still provides access.

   The passwordless-sudo tradeoff: anything that reaches the `deploy` account has root.
   That is acceptable here precisely because reaching the account requires being in the
   tailnet or holding the master key.

4. **Tailscale** — installs via the official script (skipped if already present), then
   `tailscale up --authkey … --hostname … --ssh`, polling up to 30s for a tailnet IPv4
   to confirm the join actually succeeded. `--ssh` enables Tailscale SSH, giving you a
   second, key-independent way in.

5. **Harden sshd** — writes `/etc/ssh/sshd_config.d/99-hardening.conf`:

   ```
   PasswordAuthentication no
   ChallengeResponseAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin prohibit-password   # or 'no' when DISABLE_ROOT_SSH=true
   ```

   Validated with `sshd -t` before reload, so a bad config can never leave you with a
   dead SSH daemon. Ubuntu 24.04 uses the `ssh` unit, older releases `sshd`; the script
   reloads whichever exists.

   **Ordering matters:** this runs *before* the firewall is enabled. Enabling UFW cuts
   any SSH session on the public IP, which would kill the script mid-run — so all
   config that must complete is done first, and `ufw --force enable` is the last action.

6. **Firewall (UFW)** — default deny incoming, allow outgoing, then:
   - `41641/udp` for Tailscale direct connections (without it Tailscale falls back to
     relayed DERP connections — it works, just slower).
   - `80`/`443/tcp` from each Cloudflare range only, when `ALLOW_CLOUDFLARE_WEB=true`.
     Ranges are fetched live from <https://www.cloudflare.com/ips-v4> and `-v6`, with a
     pinned fallback list inlined in the script if the fetch fails. Prefer the live
     fetch: a stale pinned list means legitimate Cloudflare traffic gets dropped.
   - Port 22 per the lockout-safe rule below.

## The lockout-safe (fail-open) rule — important

SSH is only restricted to the tailnet **after** Tailscale is confirmed up:

- **Tailscale confirmed up** → `ufw allow in on tailscale0 to any port 22 proto tcp`,
  and any prior public `allow 22/tcp` rule is deleted. Only tailnet devices reach SSH.
- **Tailscale NOT confirmed** → `ufw allow 22/tcp`; public SSH stays **open** and the
  script logs a loud warning. This is deliberate: a failed Tailscale join must never
  lock you out of a box you just created.

If you hit the fail-open path: fix Tailscale (usually an expired or single-use auth
key), confirm you can reach the box over the tailnet, then close public SSH by hand:

```bash
ufw delete allow 22/tcp
```

Do not skip the verification step. Closing port 22 while the tailnet is broken is
exactly the lockout the fail-open behaviour exists to prevent. On Hetzner, recovery
means the console's rescue system — possible, but a bad afternoon.

## Idempotency & re-runs

Safe to re-run. The deploy user is created conditionally, UFW rules are re-asserted
(UFW skips duplicates), and the sshd drop-in is overwritten in place. Re-running never
undoes the hardening.

Re-run when you want to change config — e.g. once `deploy` access is verified:

```bash
ssh root@<server-name> 'DISABLE_ROOT_SSH=true bash /tmp/lockdown.sh'
```

## Verifying the result

From your machine, over the tailnet:

```bash
ssh deploy@<server-name> 'sudo ufw status verbose'   # default deny, tailscale0:22, CF rules
ssh deploy@<server-name> 'sudo sshd -T | grep -Ei "passwordauth|permitrootlogin"'
```

From outside the tailnet, confirm public SSH is closed:

```bash
nc -vz -w 5 <public-ip> 22   # should time out / be refused
```

## Notes

- Hetzner's own Cloud Firewall is a separate, optional layer in front of UFW. This
  script does not touch it; if you use both, keep the rules consistent or you will
  chase phantom connectivity bugs.
