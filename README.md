<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 K. S. Ernest (iFire) Lee -->

# taskweft/deploy

Hosted **Taskweft MCP server** on Fly.io: `https://taskweft-mcp.fly.dev`, gated
by an OAuth 2.1 bridge to GitHub login.

It wraps the whole taskweft featureset (`{:taskweft, github: "taskweft/taskweft"}`
— planner NIF, MCP `plan`/`replan` tools, JSON-LD loader, temporal/civil-time)
in one thin app: a `Plug` pipeline that runs a self-hosted OAuth authorization
server (bridging to GitHub), then forwards authenticated requests to
`ExMCP.HttpPlug`.

## Why an OAuth bridge?

MCP clients expect to speak standard OAuth to the server they connect to — RFC
8414 discovery metadata, RFC 7591 dynamic client registration, PKCE
authorization-code. GitHub doesn't offer any of that directly (no metadata
endpoint, no DCR, no PKCE support for public clients), so this app is a small
authorization server that speaks MCP-compliant OAuth to the client and uses
GitHub (via [Assent](https://hex.pm/packages/assent), DB-free) as the upstream
identity provider.

### Everything is stateless

Every OAuth artifact — the dynamic-registration `client_id`, the GitHub-leg
`state`, our authorization `code`, and the MCP access token — is a
self-owned **macaroon** (`TaskweftDeploy.Macaroon`, HMAC-SHA256 caveat chain;
see `lib/taskweft_deploy/artifact.ex`). There is no database, volume, or ETS
table: nothing is lost when the machine scales to zero and restarts, because
each artifact carries its own signed, expiring payload.

## Auth flow

1. Your MCP client calls the server without a token → **401** with a
   `WWW-Authenticate` header pointing at
   `/.well-known/oauth-protected-resource`.
2. The client discovers the flow (`/.well-known/oauth-authorization-server`),
   dynamically registers itself (`POST /oauth/register`), and redirects you to
   `/oauth/authorize` → GitHub sign-in.
3. GitHub redirects back to `/oauth/callback`; we exchange the code, check the
   login against the whitelist, and hand the client our own authorization code.
4. The client exchanges that for an access token at `/oauth/token` (PKCE
   verified) and uses it as `Authorization: Bearer <token>` on every MCP call.

`/health` is the only unauthenticated route (Fly checks).

### Whitelist

`TASKWEFT_MCP_GH_ALLOW` (Fly env, non-secret) is a comma list: bare entries are
GitHub logins, `@name` entries are org memberships — e.g.
`fire,@taskweft,@V-Sekai-fire,@V-Sekai`.

We request only the `read:user,user:email` GitHub scopes — **never
`read:org`**, whose consent screen is "read your organization, team
membership, and private project boards," far more than a whitelist gate
needs. Without `read:org`, `GET /user/orgs` still lists the caller's **public**
org memberships, which is what the org check uses. A private-only membership
won't match; make it public, or rely on being whitelisted by login directly.

### MCP client config

```json
{ "mcpServers": { "taskweft": { "type": "http", "url": "https://taskweft-mcp.fly.dev/" } } }
```

No header needed — the client discovers and drives the OAuth flow itself.

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

Fly app secrets (`fly secrets set -a taskweft-mcp`), never in git:

- `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` — the GitHub OAuth App
  (callback URL: `https://taskweft-mcp.fly.dev/oauth/callback`).
- `TASKWEFT_TOKEN_SECRET` — the macaroon root key. Must be stable (not
  regenerated on every deploy) or every outstanding token invalidates.

## Local test (WSL + podman quadlet)

```sh
podman build -t taskweft-mcp -f Containerfile .
cp deploy/taskweft-mcp.container ~/.config/containers/systemd/
systemctl --user daemon-reload && systemctl --user start taskweft-mcp
curl -s localhost:8080/health                                        # ok (no auth)
curl -s localhost:8080/.well-known/oauth-authorization-server         # discovery metadata
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/ -d '{}'  # 401 (no token)
```

Full OAuth round-trips (register → authorize → GitHub → callback → token) need
a real GitHub OAuth App, since GitHub is the identity provider — there's no
local stand-in for that leg.
