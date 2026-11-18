# Container Control

Turn your Mac's development projects (Node, Docker Compose, Dockerfile or any command) on and off from the menu bar, the terminal or an AI agent.

Requires macOS 15 or later and Swift 6.

## Architecture

```
SwiftUI app ─┐
cctl (CLI) ──┼──▶ ControlCore ──▶ launchd (node, custom)
cctl mcp ────┘        │           docker  (compose, dockerfile)
                      ▼
          ~/.config/container-control/
            projects.json   registered projects
            activity.jsonl  who started or stopped what
            logs/<id>.log   output of launchd projects
            launchd/        generated plists (they don't start at login)
            logos/          uploaded logos
            requests/       agent requests waiting for your approval
```

- Projects **keep running after you quit the app**: Node runs as a launchd job and Docker is independent.
- Commands run with the PATH of your interactive zsh (nvm, Homebrew, OrbStack), resolved once and cached for an hour.
- Stopping a Node project kills its whole process group through launchd, so no orphaned children are left holding the port.

## App

```bash
./scripts/build-app.sh --install   # builds and copies it to ~/Applications
open ~/Applications/"Container Control.app"
```

- **Menu bar**: the project list with logo, state and a switch to turn each one on or off. Double-click opens the project in the window.
- **Window**: a grid of cards. Drop folders on it to add projects. Clicking a card opens a panel to edit the name, logo (drop an image), commands, port, environment variables and agent permission.
- The app picks up changes made from `cctl` or by agents: it watches the config folder and polls state every 4 seconds.
- **Live logs** per project (right-click → View Logs, or the Logs button in the panel), with filtering, auto-follow and highlighted errors.
- **Activity**: who started, stopped or changed each project, with a filter to show only agents. Each project's panel shows its latest actions.
- **Notifications** when an agent starts or stops something (can be turned off in Settings).
- **Settings** (⌘,): open at login, notifications, install `cctl` into `~/.local/bin`.

## `.localhost` domains

Every project opens at `http://<id>.localhost` (for example `http://acme-admin.localhost`), and `http://localhost` shows an index of projects. The **Domain** field in the panel, or `cctl set <id> --domain acme`, gives it a name of its own (`http://acme.localhost`, dots allowed, like `admin.acme`). `<id>.localhost` keeps working as an alias. Turn it on in **Settings → Domains** or with `cctl proxy install`.

- A proxy (`cctl proxy run`) runs as a launchd service at login, even when the app is closed. It listens on port 80 and only accepts connections from this Mac.
- It reads the host from the first request and passes the traffic through untouched to the project's port, so websockets (Vite hot reload), streaming and keep-alive work. Subdomains (`api.acme-admin.localhost`) go to the same project.
- When the project is stopped, it shows a page that reloads itself until you start it.
- macOS resolves `*.localhost` to your Mac system-wide, so it works in every browser and also with `curl` and Node's `fetch`.
- Each project also gets its own origin, so cookies no longer leak between projects the way they do with `localhost:3000` and `localhost:3001`.

**Automatic ports:** when you start a project whose port is taken, Container Control gives it a free one between 4100 and 4999, saves it and records it in the activity log. It only does this where it can force the port safely:

| Project | How |
|---|---|
| Node with Vite, Next, Astro, Nuxt or Remix | The framework's flag (`--port N --strictPort`, `-p N`) plus `PORT` |
| Node with another server | `PORT`. If it isn't listening on the new port after starting, it's stopped, the port is restored and the reason is explained |
| Compose with the port in a variable (`"${WEB_PORT:-3000}:3000"`) | That variable on `up` |
| Dockerfile | `-p new:container_port` |
| Compose with a fixed port, or a script that already passes `--port` | Not moved: the error says which process or project holds the port |

## Publishing to the internet (Cloudflare)

In the project panel, **Publish with Cloudflare…**, or `cctl publish <id>`, gives it a temporary public link such as `https://random-words.trycloudflare.com` through a [Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/). `cctl unpublish <id>` closes it.

- Requires `cloudflared` (`brew install cloudflared`), but no Cloudflare account.
- **The link is disposable:** it changes every time you publish and disappears when you unpublish, when `cloudflared` exits or when the Mac restarts. In those cases the app marks the project as unpublished.
- Publishing takes about 10–20 seconds. The app waits for the hostname to exist in public DNS (asking 1.1.1.1 directly, so macOS doesn't cache a "doesn't exist") and for the tunnel to respond, so the link works as soon as you get it.
- The tunnel goes through the domains proxy with `Host: <name>.localhost`. That way Vite and other dev servers accept it and, when the project is stopped, visitors see the "stopped" page (503, because Cloudflare replaces 502s with its own error page). Without the proxy, the tunnel goes straight to `localhost:<port>`.
- Quick Tunnels have no uptime guarantee: use them for demos and testing, not for sensitive data.
- An agent can ask to publish or unpublish, but it always waits for your approval in the app.

## CLI

```bash
swift build -c release
cp .build/release/cctl /usr/local/bin/   # or any folder on your PATH

cctl add ~/Projects/my-api --name "My API" --logo ~/Desktop/logo.png
cctl list
cctl start my-api
cctl logs my-api -f
cctl stop my-api
cctl activity
cctl --help
```

## AI agents

Agents can use `cctl` from the terminal or connect over MCP. In the app, **Settings → Connect AI agents** copies ready-to-paste configuration.

```bash
# Claude Code
claude mcp add --scope user container-control -- ~/.local/bin/cctl mcp
```

```json
// Claude Desktop, Cursor and other MCP clients
{ "mcpServers": { "container-control": { "command": "/Users/<you>/.local/bin/cctl", "args": ["mcp"] } } }
```

The MCP server has everything the CLI has, except approving or denying requests (an agent doesn't approve its own):

| Tools | Who decides |
|---|---|
| `list_projects`, `project_status`, `project_logs`, `project_activity`, `list_requests`, `detect_project`, `system_status` | Free (read-only) |
| `register_project` | Free |
| `start_project`, `stop_project`, `restart_project`, `update_project` | The project's permission |
| `remove_project`, `publish_project`, `unpublish_project`, `set_agent_permission`, `set_domains` | Always your approval in the app |

**Why MCP as well as the CLI?** For agents with a terminal, `cctl` is enough and uses less context. MCP serves clients without a terminal (Claude Desktop, mobile), identifies the client without relying on environment variables and declares which tools are read-only or destructive. Both are thin layers over the same `ControlCore`.

**Registering the project you're working on:** ask the agent to "register this project in Container Control". It uses `register_project`, or `cctl add` from the folder (with no arguments, `cctl add` registers the current folder). It detects the kind, name, command, port and logo, and the agent can correct any of them when registering or later with `update_project` (`cctl set`): name, kind, commands, port, compose file, domain, environment variables and logo.

Claude Code, Codex and Gemini CLI are detected automatically. Over MCP the client's name is used, for example "Claude Desktop", and `CCTL_ACTOR="<name>"` sets the name by hand. Each project has an agent permission (`cctl set <id> --agents ...` or the project panel):

| Permission | What the agent can do |
|---|---|
| `none` | Doesn't see the project |
| `read` | See its state and logs |
| `control` (default) | Also start, stop and restart it |
| `confirm` | Same as `control`, but every action waits for your approval |

**Confirmation:** the agent creates a request in `requests/` and waits up to 90 seconds (`CCTL_CONFIRM_TIMEOUT`). The app shows a notification with Allow and Deny buttons, plus a notice in the menu bar and the window. If you approve, the app runs the action, not the agent. You can also answer with `cctl requests`, `cctl approve <id>` or `cctl deny <id>`. If the app isn't open, the request is denied immediately.

Agents can register new projects, which always get the default permission (`control`), and change the settings of projects they control (with `confirm`, the request shows what they want to change). Removing, publishing or unpublishing, changing permissions and turning domains on or off can be *requested*, but always wait for your approval. Agents can never move a project's folder or approve requests. Agents with `read` permission don't see environment variable values. This protects against agents that make mistakes, not against malicious ones: an agent with terminal access could edit the config files directly.

## Development

```bash
swift build
swift test
CCTL_SNAPSHOT=/tmp/shots .build/debug/ContainerControl   # renders the UI to PNGs and exits
CCTL_HOME=/tmp/cctl-dev .build/debug/cctl list            # isolated config
```

## License

[MIT](LICENSE)
