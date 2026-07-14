# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.GithubAuth do
  @moduledoc """
  Plug that gates a request behind a GitHub identity whitelist.

  The caller presents their own GitHub token as `Authorization: Bearer <token>`.
  We resolve it against GitHub (`/user`, and `/user/orgs` only if a login match
  fails and orgs are configured) and allow the request iff the login is
  whitelisted or the user belongs to a whitelisted org. Results are cached by a
  SHA-256 of the token for `@ttl_ms` so we don't call GitHub on every request.

  The whitelist is read at runtime from `:persistent_term` (set in
  `TaskweftDeploy.Application`). `/health` (and anything in `:exempt`) bypasses
  auth so Fly health checks work.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @cache :taskweft_gh_auth_cache
  @ttl_ms 5 * 60 * 1000
  @api "https://api.github.com"

  @impl true
  def init(opts), do: Keyword.get(opts, :exempt, ["/health"])

  @impl true
  def call(conn, exempt) do
    if conn.request_path in exempt do
      conn
    else
      case extract_token(conn) do
        {:ok, token} -> authorize(conn, token)
        :error -> deny(conn, 401, "missing_bearer_token")
      end
    end
  end

  defp authorize(conn, token) do
    case check(token, whitelist()) do
      {:ok, login} ->
        assign(conn, :github_login, login)

      {:error, :unauthorized} ->
        deny(conn, 401, "invalid_github_token")

      {:error, :forbidden} ->
        deny(conn, 403, "not_in_whitelist")

      {:error, _} ->
        deny(conn, 503, "github_auth_unavailable")
    end
  end

  defp whitelist, do: :persistent_term.get({:taskweft_deploy, :auth}, %{logins: MapSet.new(), orgs: MapSet.new()})

  # ---- token → identity, with a short-lived positive/negative cache ----

  defp check(token, wl) do
    key = :crypto.hash(:sha256, token)
    now = System.monotonic_time(:millisecond)

    case cache_get(key, now) do
      {:hit, result} ->
        result

      :miss ->
        result = lookup(token, wl)
        # Cache identity verdicts, not transient service errors.
        unless match?({:error, :service}, result), do: cache_put(key, result, now)
        normalize(result)
    end
  end

  defp normalize({:error, :service}), do: {:error, :service}
  defp normalize(other), do: other

  defp lookup(token, wl) do
    case gh_login(token) do
      {:ok, login} ->
        cond do
          MapSet.member?(wl.logins, login) ->
            {:ok, login}

          MapSet.size(wl.orgs) == 0 ->
            {:error, :forbidden}

          true ->
            case gh_orgs(token) do
              {:ok, orgs} ->
                if Enum.any?(orgs, &MapSet.member?(wl.orgs, &1)),
                  do: {:ok, login},
                  else: {:error, :forbidden}

              {:error, _} ->
                {:error, :service}
            end
        end

      {:error, _} = err ->
        err
    end
  end

  # ---- GitHub API (via req; no extra HTTP-client dep beyond taskweft's) ----

  defp gh_login(token) do
    case gh_get("/user", token) do
      {:ok, 200, %{"login" => login}} when is_binary(login) -> {:ok, login}
      {:ok, 401, _} -> {:error, :unauthorized}
      {:ok, 403, _} -> {:error, :unauthorized}
      _ -> {:error, :service}
    end
  end

  defp gh_orgs(token) do
    case gh_get("/user/orgs", token) do
      {:ok, 200, orgs} when is_list(orgs) ->
        {:ok, Enum.map(orgs, & &1["login"]) |> Enum.reject(&is_nil/1)}

      _ ->
        {:error, :service}
    end
  end

  defp gh_get(path, token) do
    Req.get(@api <> path,
      headers: [
        {"authorization", "Bearer " <> token},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "taskweft-mcp"},
        {"x-github-api-version", "2022-11-28"}
      ],
      retry: false,
      receive_timeout: 5_000
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # ---- ETS cache ----

  defp cache_get(key, now) do
    case :ets.lookup(@cache, key) do
      [{^key, result, exp}] when exp > now -> {:hit, result}
      _ -> :miss
    end
  end

  defp cache_put(key, result, now) do
    :ets.insert(@cache, {key, result, now + @ttl_ms})
    result
  end

  # ---- helpers ----

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, token}
      _ -> :error
    end
  end

  defp deny(conn, status, code) do
    body = Jason.encode!(%{error: code})

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("www-authenticate", ~s(Bearer realm="taskweft-mcp"))
    |> send_resp(status, body)
    |> halt()
  end
end
