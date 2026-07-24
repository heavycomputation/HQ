<h1 align="center">HQ</h1>

<p align="center">
  <b>A home base for provisioning and operating your own servers — driven by the coding agent you already use.</b>
</p>

<p align="center"><i>by <a href="https://heavycomputation.com">heavycomputation</a></i></p>

---

Every time you ship something, you provision a box, lock it down the same way,
and then spend the rest of the project SSHing in to deploy, maintain, and debug
it. HQ is a lightweight home for handing that work to an agent instead.

Clone this repo, add your secrets to `.env`, and point your coding agent
(Claude Code, Codex, Gemini CLI, …) at it. From there you build up:

- **Skills** — repeatable, scriptable procedures (provision a box, harden it,
  deploy an app) your agent runs on demand.
- **Server context** — a folder per live box under [`servers/`](servers/) holding
  the standing context an agent needs to operate it: what's deployed, where the
  logs are, the gotchas, and any per-box ops scripts.

This repo is the **raw scaffolding** — an empty frame you grow into your own HQ.
It ships with no skills and no agent config; you add those as you go, so every
capability is one you understand and trust.

## Setup

```bash
cp .env.example .env    # then fill in your secrets
```

`.env` holds live secrets and is gitignored — never commit it.

## `servers/` — your live boxes

Each `servers/<name>/` folder is an agent's standing context for one real box.
Copy the [`your-app-name`](servers/your-app-name/) template per box and have your
agent keep it current.

> Treat each `servers/<box>/` you add as private — it describes real
> infrastructure. This repo's `.gitignore` keeps new boxes untracked; only the
> `your-app-name` template is committed.

## License

[MIT](LICENSE)
