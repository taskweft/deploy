# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Router do
  @moduledoc """
  `/health` (unauthenticated, for Fly checks) plus every MCP request gated by
  `TaskweftDeploy.GithubAuth` and forwarded to `ExMCP.HttpPlug`.

  `ExMCP.HttpPlug` routes internally: POST on any path is the JSON-RPC endpoint,
  GET `/sse` (or `Accept: text/event-stream`) is the SSE channel. We pass
  `validate_origin: false` because non-browser MCP clients don't send an Origin.
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(TaskweftDeploy.GithubAuth, exempt: ["/health"])
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  forward("/",
    to: ExMCP.HttpPlug,
    init_opts: [
      handler: Taskweft.MCP.Server,
      server_info: %{name: "taskweft", version: "0.1.0"},
      tools: [],
      sse_enabled: true,
      cors_enabled: true,
      validate_origin: false
    ]
  )

  match _ do
    send_resp(conn, 404, "not found")
  end
end
