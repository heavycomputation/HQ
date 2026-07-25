# HQ

This is HQ, a central repo from which we will provision, configure, maintain, and debug Hetzner VPS machines running my applications.

# Project structure

**servers/** - each box gets its own folder in here which will contain all the relevant context around the machine and the app. Most of the ongoing work will be in this folder, with files being updated and created and deleted over the lifetime of a server

**skills/** - a repository for repeatable scripts, setups, configurations, and other agent instructions I intend to invoke on multiple machines

**.env.example** - a template env file with placeholder fields for the Hetzner API and Tailscale auth key. A real .env file with populated values should exist

**readme.md** - user-facing readme file which you should not read unless explicitly asked. AGENTS.md is a sufficient entry point to gain context on the project.

# Provisioning

When provisioning a server, ask step-by-step for answers to the configuration settings. How much RAM, x86 or ARM, location, etc. Don't assume, and always ask one step at a time to allow for easy Q&A back and forth. Keep responses extra concise during this setup stage. This rule can be overriden if I point you to a skill for provisioning or if I've asked you to make the decisions.

After provisioning a server, always create an AGENTS.md file at **servers/project-name/AGENTS.md** with a section detailing the basics of the machine for all future agent reference.

# Setup

All new servers should be locked down and secured before the bulk of the work is initiated. HQ comes preloaded with **skills/lockdown** which shows you how to lock down a server with Tailscale and Cloudflare so that only we can ssh in from this machine. This rule can be overriden if a user asks or if another security method is provided.

After setting up the server, always add a section in **servers/project-name/AGENTS.md** explaining in brief the setup you performed or cite the specific skill you used (such as **skills/lockdown** to save re-explaining an existing skill).

# Workflow

Most work will take place in **servers/** on a particular project. Take care to update the server project's AGENTS.md file with critical information a future agent may need. Be critical about updating the file - we don't want AGENTS.md becoming uber long and full of logs which may distract future agents.

