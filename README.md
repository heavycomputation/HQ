# HQ

A central repository from which you can deploy agents to provision, maintain, and debug Hetzner VPS machines running your applications.

## Project requirements

**Mandatory**

- Hetzner account
- Tailscale account
- Access to a CLI agent like Claude Code, Codex, or Grok Build

**Optional but recommended**
- Cloudflare account

## Getting started

On your machine:

```bash
git clone https://github.com/heavycomputation/HQ hq && cd hq && cp .env.example .env
```

You need exactly two credentials in that `.env`:

- **`HETZNER_API_TOKEN`** — Hetzner Cloud Console → Security → API Tokens (Read & Write)
- **`TAILSCALE_API_KEY`** — Tailscale admin → Settings → Keys → Generate API key

That is the whole setup. Everything else — the tailnet policy, auth keys, the server
itself — your agent handles from those two.

Install Tailscale on your own machine and sign into the same tailnet, since that is how
you reach your servers. Then boot your agent and ask it to provision a new server.

## License

[MIT](LICENSE)
