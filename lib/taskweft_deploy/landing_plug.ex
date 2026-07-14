# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.LandingPlug do
  @moduledoc """
  A minimal, static, unauthenticated landing page at `GET /` — not the MCP
  endpoint (that's `/mcp`, see `TaskweftDeploy.Router`). Dependency-free: no
  template engine, no JS, just an inlined stylesheet.
  """

  @behaviour Plug

  import Plug.Conn
  alias TaskweftDeploy.BaseURL

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html(BaseURL.get(conn) <> "/mcp"))
  end

  defp html(mcp_url) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>taskweft</title>
    <style>
      :root { color-scheme: light dark; }
      body {
        font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        max-width: 34rem; margin: 4rem auto; padding: 0 1.25rem;
      }
      code, pre { font: 13px/1.5 ui-monospace, Menlo, Consolas, monospace; }
      pre {
        background: color-mix(in srgb, currentColor 6%, transparent);
        padding: .9rem 1rem; border-radius: .5rem; overflow-x: auto;
      }
      a { color: inherit; }
    </style>
    </head>
    <body>
      <h1>taskweft</h1>
      <p>Hosted HTN planner MCP server — <code>plan</code> / <code>replan</code>
        over JSON-LD domains, gated by GitHub sign-in (OAuth 2.1).</p>
      <pre>{ "mcpServers": { "taskweft": {
      "type": "http",
      "url": "#{mcp_url}"
    } } }</pre>
      <p>No header needed — the client discovers and drives the OAuth flow.</p>
      <p><a href="https://github.com/taskweft/deploy">taskweft/deploy</a> ·
        <a href="https://github.com/taskweft/taskweft">taskweft/taskweft</a></p>
    </body>
    </html>
    """
  end
end
