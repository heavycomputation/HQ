# HQ

A central repository from which you can deploy agents to provision, maintain, and debug Hetzner VPS machines running your applications.

## Project requirements

**Mandatory**

- Hetzner account
- Access to a CLI agent like Claude Code, Codex, or Grok Build
- SSH key on your local machine and set in Hetzner

**Optional but recommended**
- Tailscale account
- Cloudflare account

## Getting started

On your machine:

```bash
git clone https://github.com/heavycomputation/HQ hq && cd hq && cp .env.example .env
```

Then populate fields in new .env file with real secrets

Finally boot your agent and ask it to provision a new server

## License

[MIT](LICENSE)