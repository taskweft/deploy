<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 K. S. Ernest (iFire) Lee -->

# taskweft/deploy

Hosted **Taskweft MCP server** on Fly.io, gated by a GitHub identity whitelist.

It wraps the whole taskweft featureset (`{:taskweft, github: "taskweft/taskweft"}`
— planner NIF, MCP `plan`/`replan` tools, JSON-LD loader, temporal/civil-time)
in one thin app: a `Plug` pipeline that authenticates the caller's GitHub token
against a whitelist, then forwards to `ExMCP.HttpPlug`.

## Auth

Send your GitHub token as a bearer header:

```
Authorization: Bearer <github-token>
```

The server calls the GitHub API with it: the request is allowed iff the token's
login is whitelisted, or (if orgs are configured) the user belongs to a
whitelisted org. Verdicts are cached ~5 min by a hash of the token.

`TASKWEFT_MCP_GH_ALLOW` (env, non-secret) is a comma list: bare entries are
logins, `@name` / `org:name` entries are org memberships. Default `fire`.

`/health` is unauthenticated (Fly checks).

### MCP client config

```json
{ "mcpServers": { "taskweft": {
  "type": "http",
  "url": "https://taskweft-mcp.fly.dev/",
  "headers": { "Authorization": "Bearer <github-token>" }
} } }
```

## Cost

`shared-cpu-1x` 256 MB with scale-to-zero (`auto_stop_machines`,
`min_machines_running = 0`): ~$2/mo if always on, well under $1/mo idle. TLS is
free at Fly's edge (`force_https`). No volume/DB.

## Deploy

CI (`.github/workflows/deploy.yml`) runs `flyctl deploy` on push to `main`,
using the `FLY_API_TOKEN` repo secret. Manual:

```sh
fly deploy
```

Secrets live in GitHub Actions / Fly, never in git. The runtime needs **no**
GitHub secret — auth uses the caller's own token.

## Local test (WSL + podman quadlet)

```sh
podman build -t taskweft-mcp -f Containerfile .
cp deploy/taskweft-mcp.container ~/.config/containers/systemd/
systemctl --user daemon-reload && systemctl --user start taskweft-mcp
curl -s localhost:8080/health                                   # ok (no auth)
curl -s -X POST localhost:8080/ -H 'Authorization: Bearer <gh>' \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'           # 200 if whitelisted
```
