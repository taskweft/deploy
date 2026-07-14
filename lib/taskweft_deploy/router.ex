# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Router do
  @moduledoc """
  HTTP surface for the hosted MCP server:

    * `GET /health` — unauthenticated liveness (Fly checks).
    * `GET /.well-known/oauth-protected-resource` and
      `GET /.well-known/oauth-authorization-server` — OAuth discovery (RFC 9728 / 8414).
    * `POST /oauth/register` — dynamic client registration (RFC 7591).
    * `GET  /oauth/authorize` — start the flow; redirects to GitHub login.
    * `GET  /oauth/callback` — GitHub redirect; issues our authorization code.
    * `POST /oauth/token` — exchange code (+ PKCE) for a macaroon access token.
    * everything else — the MCP endpoint (`ExMCP.HttpPlug`), gated by
      `mcp_guard`, which requires a valid macaroon bearer and answers 401 with a
      `WWW-Authenticate` pointing at the resource metadata so clients discover the flow.

  We never run `Plug.Parsers`, so `ExMCP.HttpPlug` still sees the raw MCP body;
  OAuth bodies are read explicitly.
  """

  use Plug.Router
  require Logger

  alias TaskweftDeploy.OAuth

  plug(Plug.Logger)
  plug(:match)
  plug(:mcp_guard)
  plug(:dispatch)

  @mcp_init [
    handler: Taskweft.MCP.Server,
    server_info: %{name: "taskweft", version: "0.1.0"},
    tools: [],
    sse_enabled: true,
    cors_enabled: true,
    validate_origin: false
  ]

  # Version follows the dev/beta/rc/release ladder (v<major>.<minor>.<patch>-<stage>.<N>);
  # bump alongside the git tag created after each deploy.
  @release_version "0.1.0-beta.1"

  get "/health" do
    send_json(conn, 200, %{"status" => "ok", "version" => @release_version})
  end

  get "/.well-known/oauth-protected-resource" do
    send_json(conn, 200, OAuth.protected_resource_metadata(base_url(conn)))
  end

  get "/.well-known/oauth-authorization-server" do
    send_json(conn, 200, OAuth.authorization_server_metadata(base_url(conn)))
  end

  post "/oauth/register" do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, req} <- Jason.decode(body),
         {:ok, registration} <- OAuth.register_client(req) do
      send_json(conn, 201, registration)
    else
      {:error, reason} -> send_json(conn, 400, %{"error" => "invalid_client_metadata", "detail" => inspect(reason)})
      _ -> send_json(conn, 400, %{"error" => "invalid_client_metadata"})
    end
  end

  get "/oauth/authorize" do
    conn = fetch_query_params(conn)

    case OAuth.authorize(base_url(conn), conn.query_params) do
      {:ok, github_url} -> redirect(conn, github_url)
      {:error, _} -> send_json(conn, 400, %{"error" => "invalid_request"})
    end
  end

  get "/oauth/callback" do
    conn = fetch_query_params(conn)

    case OAuth.callback(base_url(conn), conn.query_params) do
      {:ok, client_redirect} -> redirect(conn, client_redirect)
      {:error, _} -> send_json(conn, 400, %{"error" => "invalid_request"})
    end
  end

  post "/oauth/token" do
    with {:ok, body, conn} <- read_body(conn),
         params = URI.decode_query(body),
         {:ok, token_response} <- OAuth.token(base_url(conn), params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_json(200, token_response)
    else
      {:error, oauth_error} -> send_json(conn, 400, %{"error" => to_string(oauth_error)})
      _ -> send_json(conn, 400, %{"error" => "invalid_request"})
    end
  end

  # Catch-all: the MCP endpoint. ExMCP.HttpPlug routes POST (JSON-RPC) on any
  # path and GET /sse; mcp_guard has already enforced a valid macaroon bearer.
  forward("/", to: ExMCP.HttpPlug, init_opts: @mcp_init)

  # ── auth gate for the MCP endpoint ──────────────────────────────────────────

  defp mcp_guard(conn, _opts) do
    if public_path?(conn), do: conn, else: require_bearer(conn)
  end

  defp public_path?(conn) do
    p = conn.request_path
    p == "/health" or String.starts_with?(p, "/.well-known/") or String.starts_with?(p, "/oauth/")
  end

  defp require_bearer(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, login} <- OAuth.verify_access(token) do
      assign(conn, :github_login, login)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    resource = base_url(conn) <> "/.well-known/oauth-protected-resource"

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{resource}", error="invalid_token")
    )
    |> send_json(401, %{"error" => "invalid_token"})
    |> halt()
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp send_json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp redirect(conn, url) do
    conn
    |> put_resp_header("location", url)
    |> send_resp(302, "")
  end

  # Public base URL. Prefer PUBLIC_BASE_URL (stable issuer); else derive from the
  # Fly edge's forwarded headers (TLS terminates there, so scheme is https).
  defp base_url(conn) do
    case :persistent_term.get({:taskweft_deploy, :base_url}, nil) do
      url when is_binary(url) ->
        url

      _ ->
        proto = header(conn, "x-forwarded-proto", Atom.to_string(conn.scheme))
        host = header(conn, "x-forwarded-host", host_with_port(conn))
        proto <> "://" <> host
    end
  end

  defp host_with_port(%Plug.Conn{host: h, port: p}) when p in [80, 443], do: h
  defp host_with_port(%Plug.Conn{host: h, port: p}), do: "#{h}:#{p}"

  defp header(conn, name, default) do
    case get_req_header(conn, name) do
      [v | _] -> v
      _ -> default
    end
  end
end
