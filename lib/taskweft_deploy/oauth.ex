# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.OAuth do
  @moduledoc """
  An OAuth 2.1 authorization server that bridges MCP clients to GitHub login.

  MCP clients speak standard OAuth to us — RFC 8414 metadata, RFC 7591 dynamic
  client registration, PKCE authorization-code — and we use GitHub (via Assent,
  the DB-free client lib `pow_assent` wraps) as the upstream identity. GitHub
  can't be an MCP authorization server directly (no metadata endpoint, no DCR,
  no PKCE public clients), which is why this bridge exists.

  Every artifact (client_id, state, code, access token) is a stateless macaroon
  (`TaskweftDeploy.Artifact`); nothing is persisted, so it survives scale-to-zero.

  Config comes from `:persistent_term` (set in `TaskweftDeploy.Application`):
  the GitHub OAuth app credentials and the login/org whitelist.
  """

  alias TaskweftDeploy.Artifact

  @github_authorize "https://github.com/login/oauth/authorize"

  # ── Discovery metadata ──────────────────────────────────────────────────────

  def protected_resource_metadata(base) do
    %{
      "resource" => base,
      "authorization_servers" => [base],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => ["mcp"],
      "resource_name" => "Taskweft MCP"
    }
  end

  def authorization_server_metadata(base) do
    %{
      "issuer" => base,
      "authorization_endpoint" => base <> "/oauth/authorize",
      "token_endpoint" => base <> "/oauth/token",
      "registration_endpoint" => base <> "/oauth/register",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => ["mcp"],
      "service_documentation" => "https://github.com/taskweft/deploy"
    }
  end

  # ── Dynamic client registration (RFC 7591) ──────────────────────────────────

  @doc "Register a public client; the client_id is a macaroon carrying its redirect_uris."
  def register_client(%{"redirect_uris" => uris} = req) when is_list(uris) and uris != [] do
    if Enum.all?(uris, &valid_redirect_uri?/1) do
      name = Map.get(req, "client_name", "mcp-client")
      client_id = Artifact.mint(:client, %{"uris" => uris, "name" => name})

      {:ok,
       %{
         "client_id" => client_id,
         "redirect_uris" => uris,
         "client_name" => name,
         "token_endpoint_auth_method" => "none",
         "grant_types" => ["authorization_code"],
         "response_types" => ["code"],
         "client_id_issued_at" => System.system_time(:second)
       }}
    else
      {:error, :invalid_redirect_uri}
    end
  end

  def register_client(_), do: {:error, :invalid_client_metadata}

  # ── Authorization endpoint ──────────────────────────────────────────────────

  @doc """
  Validate an /authorize request and return the GitHub URL to redirect the user
  to. PKCE (S256) is required; `client_id` and `redirect_uri` must match a
  registration.
  """
  def authorize(base, params) do
    with {:ok, uris} <- client_redirect_uris(params["client_id"]),
         redirect_uri when is_binary(redirect_uri) <- params["redirect_uri"],
         true <- redirect_uri in uris,
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) and challenge != "" <- params["code_challenge"] do
      state =
        Artifact.mint(:state, %{
          "client_id" => params["client_id"],
          "redirect_uri" => redirect_uri,
          "cc" => challenge,
          "cs" => params["state"],
          "scope" => params["scope"] || "mcp"
        })

      query =
        URI.encode_query(%{
          "client_id" => github().client_id,
          "redirect_uri" => base <> "/oauth/callback",
          "scope" => github_scope(),
          "state" => state,
          "allow_signup" => "false"
        })

      {:ok, @github_authorize <> "?" <> query}
    else
      _ -> {:error, :invalid_request}
    end
  end

  # ── GitHub callback ─────────────────────────────────────────────────────────

  @doc """
  Handle GitHub's redirect: verify our signed state, exchange the code with
  GitHub, resolve + whitelist the login, and return a redirect back to the
  client's redirect_uri carrying our authorization code (or an error).
  """
  def callback(base, %{"code" => _code, "state" => state} = params) do
    with {:ok, ctx} <- Artifact.verify(:state, state),
         {:ok, login, token} <- github_identity(base, params, state),
         :ok <- check_whitelist(login, token) do
      code =
        Artifact.mint(:code, %{
          "client_id" => ctx["client_id"],
          "redirect_uri" => ctx["redirect_uri"],
          "cc" => ctx["cc"],
          "sub" => login
        })

      {:ok, redirect_with(ctx["redirect_uri"], %{"code" => code, "state" => ctx["cs"]})}
    else
      {:error, :forbidden} -> callback_error(state, "access_denied")
      _ -> callback_error(state, "server_error")
    end
  end

  def callback(_base, %{"state" => state} = params) do
    callback_error(state, Map.get(params, "error", "invalid_request"))
  end

  def callback(_base, _), do: {:error, :invalid_request}

  defp callback_error(state, error) do
    case Artifact.verify(:state, state) do
      {:ok, ctx} -> {:ok, redirect_with(ctx["redirect_uri"], %{"error" => error, "state" => ctx["cs"]})}
      _ -> {:error, :invalid_request}
    end
  end

  # ── Token endpoint ──────────────────────────────────────────────────────────

  @doc "Exchange an authorization code (+ PKCE verifier) for an access token."
  def token(base, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, payload} <- Artifact.verify(:code, params["code"] || ""),
         true <- params["client_id"] == payload["client_id"],
         true <- params["redirect_uri"] == payload["redirect_uri"],
         true <- pkce_ok?(params["code_verifier"], payload["cc"]) do
      access = Artifact.mint(:access, %{"sub" => payload["sub"], "aud" => base})

      {:ok,
       %{
         "access_token" => access,
         "token_type" => "Bearer",
         "expires_in" => Artifact.access_ttl(),
         "scope" => "mcp"
       }}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def token(_base, _), do: {:error, :unsupported_grant_type}

  # ── Resource-server guard ───────────────────────────────────────────────────

  @doc "Verify an MCP bearer access token; returns the GitHub login."
  def verify_access(token) do
    case Artifact.verify(:access, token) do
      {:ok, %{"sub" => login}} when is_binary(login) -> {:ok, login}
      _ -> :error
    end
  end

  # ── GitHub identity + whitelist ─────────────────────────────────────────────

  defp github_identity(base, params, state) do
    config = [
      client_id: github().client_id,
      client_secret: github().client_secret,
      redirect_uri: base <> "/oauth/callback",
      http_adapter: {Assent.HTTPAdapter.Req, []},
      # Assent reads the expected `state` from the config (callback/2), not a 3rd arg.
      session_params: %{state: state}
    ]

    case Assent.Strategy.Github.callback(config, params) do
      {:ok, %{user: user, token: token}} ->
        login = user["preferred_username"] || user["nickname"] || user["login"]
        if is_binary(login), do: {:ok, login, token}, else: {:error, :no_login}

      _ ->
        {:error, :github_exchange_failed}
    end
  end

  defp check_whitelist(login, token) do
    wl = whitelist()

    cond do
      MapSet.member?(wl.logins, login) -> :ok
      MapSet.size(wl.orgs) == 0 -> {:error, :forbidden}
      member_of_whitelisted_org?(token, wl.orgs) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp member_of_whitelisted_org?(%{"access_token" => access}, orgs) when is_binary(access) do
    case Req.get("https://api.github.com/user/orgs",
           headers: [
             {"authorization", "Bearer " <> access},
             {"accept", "application/vnd.github+json"},
             {"user-agent", "taskweft-mcp"}
           ],
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: list}} when is_list(list) ->
        list |> Enum.map(& &1["login"]) |> Enum.any?(&MapSet.member?(orgs, &1))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp member_of_whitelisted_org?(_, _), do: false

  defp github_scope do
    if MapSet.size(whitelist().orgs) > 0, do: "read:user read:org", else: "read:user"
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp client_redirect_uris(nil), do: {:error, :no_client}

  defp client_redirect_uris(client_id) do
    case Artifact.verify(:client, client_id) do
      {:ok, %{"uris" => uris}} when is_list(uris) -> {:ok, uris}
      _ -> {:error, :bad_client}
    end
  end

  defp pkce_ok?(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp pkce_ok?(_, _), do: false

  defp redirect_with(redirect_uri, params) do
    uri = URI.parse(redirect_uri)
    existing = URI.decode_query(uri.query || "")
    %{uri | query: URI.encode_query(Map.merge(existing, params))} |> URI.to_string()
  end

  # Only allow absolute http(s) redirect URIs (or loopback for local MCP clients).
  defp valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) -> true
      _ -> false
    end
  end

  defp valid_redirect_uri?(_), do: false

  defp github, do: :persistent_term.get({:taskweft_deploy, :github})
  defp whitelist, do: :persistent_term.get({:taskweft_deploy, :auth})
end
