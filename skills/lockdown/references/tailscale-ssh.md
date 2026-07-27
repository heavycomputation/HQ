# Tailscale SSH — the access model for HQ boxes

HQ boxes have no `authorized_keys` and no passwords. Administrative access is Tailscale
SSH: `tailscaled` answers port 22 on the machine's tailnet address itself and authorizes
the connection against your tailnet identity and the SSH rules in your policy file.

Set the policy up **before** you provision. A box that joins the tailnet with no rule
matching it is a box nobody can log into.

## Why this instead of SSH keys

- **Revocation actually works.** Remove a user or device from the tailnet and their
  access to every box dies at once. No hunting through `authorized_keys` files.
- **Nothing to distribute.** New box, new laptop, new agent — no key to copy, no
  host-key prompt to click through.
- **The origin is unreachable anyway.** Port 22 is bound to `tailscale0`; there is no
  public SSH surface to protect a key for.
- **Sessions can be recorded.** Tailscale SSH can stream session recordings to a
  recorder node. For a repo whose premise is agents operating live boxes, an
  auditable record of what the agent actually typed is worth having.

The tradeoff: Tailscale is now your identity broker. If their control plane is
unreachable you cannot start new sessions — existing ones and the data plane are
direct WireGuard and unaffected. Break-glass is the Hetzner console, below.

## The policy file

Tailscale admin → Access controls. Minimum viable policy for HQ:

```jsonc
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"],
  },

  "ssh": [
    {
      // Any tailnet member may SSH to any HQ server as root or deploy.
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:server"],
      "users":  ["root", "deploy"],
    },
  ],
}
```

Three things in there matter:

**`"action": "accept"`, never `"check"`.** `check` requires an interactive browser
re-authentication (12h default) before the session opens. That is a reasonable default
for a human on a laptop and a hard failure for an agent running unattended — it will
hang mid-provision waiting for a click nobody makes.

**`"dst": ["tag:server"]`.** Tailscale's stock policy grants SSH to
`autogroup:self` — devices owned by *you*. A tagged node is owned by the tailnet, not by
a person, so it is not `self` and the stock rule will not match it. Tag your servers and
target the tag explicitly.

**`"users"` must list `deploy`.** The account is created with no key and no password;
this list is the only thing that grants access to it. `autogroup:nonroot` works too if
you would rather not enumerate names.

## Tag your servers — key expiry is the real lockout risk

Generate the auth key with `tag:server` applied (Tailscale admin → Settings → Keys →
Generate auth key → Tags), and pass `TAILSCALE_TAGS='tag:server'` to `lockdown.sh`.

Tagged nodes do not expire. An **untagged** node inherits the key creator's identity and
the tailnet's node-key expiry — ~180 days by default — and when it expires the box drops
off the tailnet silently, with no SSH key to fall back on. This is the single most common
way to lose a server, and it happens months after you set it up.

If a box is already running untagged, disable key expiry for it in the admin console
(Machines → ⋯ → Disable key expiry) as a stopgap, then re-run `lockdown.sh` with the tag.

## Auth keys

- **Reusable**, so one key provisions many boxes.
- **Non-ephemeral** — ephemeral nodes are removed from the tailnet when they go offline,
  which for a server means a reboot deletes it.
- **Tagged** `tag:server`.

A leaked auth key lets someone add a node to your tailnet. It does not give them SSH to
an existing box — that still requires matching an `ssh` rule — but treat it as a serious
exposure and revoke it in the admin console.

## Break-glass: the Hetzner console

If a box falls off the tailnet, recovery is out-of-band through the Hetzner Cloud
Console: select the server → **Console** for a VNC root shell, or enable **Rescue** mode,
which boots a rescue system and shows you a fresh root password.

From that shell, `tailscale up` with a valid key restores access. If you cannot bring the
tailnet back, `ufw disable` returns the box to a reachable state so you can work out why.

## Verifying access works

Before you rely on a box:

```bash
ssh deploy@<server-name> 'whoami && sudo -n true && echo sudo ok'
tailscale status | grep <server-name>
```

If the SSH connection hangs or is refused, it is almost always the policy file — check
that a rule matches your identity as `src` and the box's tag as `dst`, and that the
account you are connecting as appears in `users`.
