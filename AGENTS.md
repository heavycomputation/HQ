# HQ

This is HQ, a central repo from which we will provision, configure, maintain, and debug Hetzner VPS machines running my applications.

# Project structure

**servers/** - each box gets its own folder in here which will contain all the relevant context around the machine and the app. Most of the ongoing work will be in this folder, with files being updated and created and deleted over the lifetime of a server

**skills/** - a repository for repeatable scripts, setups, configurations, and other agent instructions I intend to invoke on multiple machines

**.env.example** - a template env file with placeholder fields for the Hetzner API token and the Tailscale API key. A real .env file with populated values should exist

**readme.md** - user-facing readme file which you should not read unless explicitly asked. AGENTS.md is a sufficient entry point to gain context on the project.

# Access

Servers are reached over Tailscale SSH (`ssh deploy@<server-name>`), authorized by tailnet identity and the tailnet SSH policy. There are no SSH keys anywhere in this workflow — do not generate one, do not add one to a Hetzner server, and do not write to an authorized_keys file on a box. If a server is unreachable, the break-glass path is the Hetzner Cloud Console, not a key.

The two API credentials in `.env` are the whole toolkit — the user should not have to create anything else by hand. `TAILSCALE_API_KEY` is a REST token, not a node credential: use it to read and update the tailnet policy and to mint a fresh single-use auth key per box. Never put `TAILSCALE_API_KEY` into cloud-init user-data; user-data stays readable on the box after boot. **skills/lockdown** covers the exact calls.

Before changing the tailnet policy, back it up and merge additively with an `If-Match` ETag — a careless write there can lock the user out of their own tailnet.

# Provisioning

When provisioning a server, ask step-by-step for answers to the configuration settings. How much RAM, x86 or ARM, location, etc. Don't assume, and always ask one step at a time to allow for easy Q&A back and forth. Keep responses extra concise during this setup stage. This rule can be overriden if I point you to a skill for provisioning or if I've asked you to make the decisions.

Present only options that can actually be ordered. A Hetzner server type is *priced* in more locations than it is *available* in, so the price list alone will lead you to offer a box that fails to create — **skills/lockdown** has the query that accounts for availability.

Create servers with **skills/lockdown**'s script as cloud-init user-data so the box hardens itself and joins the tailnet on first boot. That is the default path — it means the machine is never touched before it is secured.

After provisioning a server, always create an AGENTS.md file at **servers/project-name/AGENTS.md** with a section detailing the basics of the machine for all future agent reference.

Exception: a throwaway box — a validation or test machine you intend to destroy in the same session — gets no `servers/` folder. Writing one leaves a directory describing a machine that no longer exists. If you did create one, delete it as part of decommissioning, and always destroy the Tailscale device alongside the Hetzner server so stale nodes don't accumulate in the tailnet.

# Setup

All new servers should be locked down and secured before the bulk of the work is initiated. HQ comes preloaded with **skills/lockdown** which shows you how to lock down a server with Tailscale and Cloudflare so that only our tailnet can reach it. This rule can be overriden if a user asks or if another security method is provided.

After setting up the server, always add a section in **servers/project-name/AGENTS.md** explaining in brief the setup you performed or cite the specific skill you used (such as **skills/lockdown** to save re-explaining an existing skill).

# Workflow

Most work will take place in **servers/** on a particular project. Take care to update the server project's AGENTS.md file with critical information a future agent may need. Be critical about updating the file - we don't want AGENTS.md becoming uber long and full of logs which may distract future agents.

