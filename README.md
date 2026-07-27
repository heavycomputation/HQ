# HQ

A central repository from which you can deploy agents to provision, maintain, and debug Hetzner VPS machines running your applications.

## Project requirements

**Mandatory**

- Hetzner account
- Tailscale account
- Access to a CLI agent like Claude Code, Codex, or Grok Build

**Optional but recommended**
- Cloudflare account

## Access model

Servers are reached over **Tailscale SSH**, not SSH keys. Boxes provision themselves on
first boot, join your tailnet, and are administered over it — you never generate a key,
never copy one to a server, and never manage an `authorized_keys` file. Access is your
Tailscale identity, so removing a person or device from your tailnet revokes them
everywhere at once.

Before provisioning your first box, add an SSH rule to your tailnet policy so you can
actually log in. See
[skills/lockdown/references/tailscale-ssh.md](skills/lockdown/references/tailscale-ssh.md).

## Getting started

On your machine:

```bash
git clone https://github.com/heavycomputation/HQ hq && cd hq && cp .env.example .env
```

Then populate fields in new .env file with real secrets

Finally boot your agent and ask it to provision a new server

## License

[MIT](LICENSE)
