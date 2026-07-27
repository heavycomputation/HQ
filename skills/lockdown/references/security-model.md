# Security model — the lockdown baseline

The detailed reference for what `scripts/lockdown.sh` does and why. Read this before
changing any firewall or SSH rule on a locked-down box.

The access model itself — Tailscale SSH, the policy file, tags, and break-glass — is
covered in [tailscale-ssh.md](tailscale-ssh.md).

## Threat posture

The box has a public IPv4/IPv6 but presents **almost no public attack surface**:

- **SSH is not reachable from the internet.** Port 22 is bound to the `tailscale0`
  interface only, where `tailscaled` answers it. Authorization is your tailnet identity
  and SSH policy — there are no keys or passwords on the box to steal or leak.
- **Web is reachable only from Cloudflare.** Ports 80/443 accept traffic only from
  Cloudflare's published ranges, so the origin sits behind Cloudflare and the origin IP
  need never appear in DNS. Optional — set `ALLOW_CLOUDFLARE_WEB=false` on a box with
  no web app and both ports stay closed.
- **Everything else is denied** by UFW's default-deny-incoming policy.

Tailscale is the only ingress path for administration. That makes the auth key and your
tailnet SSH policy the things worth protecting.

## Configuration

| Var | Default | Purpose |
|-----|---------|---------|
| `TAILSCALE_AUTHKEY` | — | **Required.** Reusable, non-ephemeral auth key. Missing → the script exits immediately. |
| `TAILSCALE_HOSTNAME` | `$(hostname)` | Hostname registered in your tailnet. |
| `TAILSCALE_TAGS` | — | ACL tags, e.g. `tag:server`. Tagged nodes never expire. |
| `CREATE_DEPLOY_USER` | `true` | Create a non-root sudo user. |
| `DEPLOY_USER` | `deploy` | Name of that user. |
| `ALLOW_CLOUDFLARE_WEB` | `true` | Open 80/443 to Cloudflare ranges only. |

## Step by step

1. **System update** — `apt-get update && upgrade`, then install `curl`, `ufw`,
   `unattended-upgrades`.

2. **Unattended security upgrades** — writes `/etc/apt/apt.conf.d/20auto-upgrades` and
   enables the `unattended-upgrades` unit, so security patches apply automatically
   without anyone logging in.

3. **Non-root deploy user** — creates `deploy` (password login disabled) in the `sudo`
   group with a `NOPASSWD` sudoers drop-in, so unattended deploys never hang on a
   password prompt. The account holds no credentials at all; you reach it through
   Tailscale SSH, which means your policy's `users` list must include `deploy`.

   The passwordless-sudo tradeoff: anything that reaches the `deploy` account has root.
   That is acceptable here precisely because reaching the account requires an identity
   your tailnet policy has already authorized.

4. **Tailscale** — installs via the official script (skipped if already present), then
   `tailscale up --authkey … --hostname … --ssh` (plus `--advertise-tags` when
   `TAILSCALE_TAGS` is set), polling up to 30s for a tailnet IPv4 to confirm the join
   actually succeeded. `--ssh` is what makes `tailscaled` answer port 22.

5. **Harden sshd** — writes `/etc/ssh/sshd_config.d/99-hardening.conf`:

   ```
   PasswordAuthentication no
   ChallengeResponseAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin no
   ```

   `sshd` is not the way in and this config is not what gates your access — Tailscale SSH
   is a separate server inside `tailscaled` and does not read `sshd_config`. `ssh
   root@<server-name>` over the tailnet works regardless of `PermitRootLogin no`. The
   drop-in exists so that if anything ever does reach `sshd`, nothing authenticates.

   Validated with `sshd -t` before reload, so a bad config can never leave you with a
   dead SSH daemon. Ubuntu 24.04 uses the `ssh` unit, older releases `sshd`; the script
   reloads whichever exists.

6. **Firewall (UFW)** — default deny incoming, allow outgoing, then:
   - `41641/udp` for Tailscale direct connections (without it Tailscale falls back to
     relayed DERP connections — it works, just slower).
   - `22/tcp` inbound **on `tailscale0` only**, where `tailscaled` is listening. Nothing
     on the public IP.
   - `80`/`443/tcp` from each Cloudflare range only, when `ALLOW_CLOUDFLARE_WEB=true`.
     Ranges are fetched live from <https://www.cloudflare.com/ips-v4> and `-v6`, with a
     pinned fallback list inlined in the script if the fetch fails. Prefer the live
     fetch: a stale pinned list means legitimate Cloudflare traffic gets dropped.

   `ufw --force enable` is the last action in the script — everything that must complete
   is done before the firewall comes up.

## The abort-before-sealing rule — important

Steps 5 and 6 only run if the tailnet join confirmed. If `tailscale up` fails, or no
tailnet IPv4 appears within 30s, the script logs the reason and **exits non-zero without
touching sshd or the firewall**.

This is deliberate. The tailnet is the only administrative ingress; sealing a box that
never reached it produces a machine nobody can log into. Aborting instead leaves it
exactly as it was — unhardened, but reachable and fixable. The script is idempotent, so
once you have a working key you just run it again.

Usual causes: an expired or single-use auth key, or a key that is not authorized to
assign the tags in `TAILSCALE_TAGS`.

## Idempotency & re-runs

Safe to re-run. The deploy user is created conditionally, UFW rules are re-asserted
(UFW skips duplicates), and the sshd drop-in is overwritten in place. Re-running never
undoes the hardening.

Re-run to change config — e.g. to add a tag to a box provisioned without one:

```bash
ssh root@<server-name> "TAILSCALE_TAGS='tag:server' bash /tmp/lockdown.sh"
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
