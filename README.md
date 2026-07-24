<h1 align="center">HQ</h1>

<p align="center">
  <b>A home base for provisioning and operating your own servers — driven by the coding agent you already use.</b>
</p>

<p align="center"><i>by <a href="https://heavycomputation.com">heavycomputation</a></i></p>

---

The problem HQ intends to solve is this: Before HQ, I would manually go into the Hetzner dashboard, provision a server, ssh in, configure it with the same security setup I always use, and deploy my app. I tend to use Rama for my app backends, so I also setup the box as a single-node rama cluster. Doing all of this each time takes several hours, and I do it infrequently enough that I forget important details and have to relearn.

I then started experimenting with using an LLM agent on the server and providing it with all the important context and references so it can do it for me. This is useful, but still not quite as easy as I want.

So, I created new local project - called it 'HQ' - and added my Hetzner API keys and tailscale auth key, a write up of the security setup I like (tailscale + Cloudflare tunnel), a document on how to setup a single node rama cluster, and my Clojure app jar file. Claude then undertook the whole setup, from provisioning the server through Hetzner, SSH'ing into the box, locking it down with my security setup, booting a rama cluster, and deploying my app.

This saved me several hours. Possibly a whole day.

But the more important finding was that I could then have Claude debug all the issues with my live app on an ongoing basis. Everytime a bug was flagged, I booted Claude, pointed it at the live server, and it found all previous context, SSH'd in, debugged, and either fixed on the spot or suggested a fix in my codebase (which my other Claude could then fix, commit, push, and uberjar).

And so HQ has become the central way in which the production-side of my apps are managed.

HQ is a central repository for managing LLM agents which are deployed onto the task of managing your Hetzner servers. It provides a lightweight scaffolded project structure which is intended to evolve and grow as the context around your desired setup grows.

## Setup

```bash
cp .env.example .env    # then fill in your secrets
```

## `servers/` — your live boxes

Each `servers/<name>/` folder is an agent's standing context for one real box.
Copy the [`your-app-name`](servers/your-app-name/) template per box and have your
agent keep it current.

> Treat each `servers/<box>/` you add as private — it describes real
> infrastructure. This repo's `.gitignore` keeps new boxes untracked; only the
> `your-app-name` template is committed.

## License

[MIT](LICENSE)
