# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Application do
  @moduledoc """
  Boots the hosted Taskweft MCP server: a Cowboy endpoint running
  `TaskweftDeploy.Router`, which bridges MCP-client OAuth to GitHub login and
  gates MCP requests behind a macaroon access token. No database, no volume —
  all OAuth state is a stateless macaroon (`TaskweftDeploy.Artifact`), so
  scale-to-zero restarts lose nothing.

  Runtime env:

    * `PORT` — listen port (default 8080; Fly maps 443/TLS → this).
    * `TASKWEFT_TOKEN_SECRET` — macaroon root key (**required in prod**; a stable
      value so tokens survive restarts). A random key is used if unset (dev only).
    * `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` — the GitHub OAuth app.
    * `TASKWEFT_MCP_GH_ALLOW` — whitelist (comma list; bare = login, `@name`/`org:name` = org). Default `fire`.
    * `PUBLIC_BASE_URL` — external URL (issuer); derived from Fly's forwarded headers if unset.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    :persistent_term.put({:taskweft_deploy, :token_secret}, token_secret())
    :persistent_term.put({:taskweft_deploy, :auth}, parse_allow(env("TASKWEFT_MCP_GH_ALLOW", "fire")))

    :persistent_term.put(
      {:taskweft_deploy, :github},
      %{client_id: env("GITHUB_CLIENT_ID", ""), client_secret: env("GITHUB_CLIENT_SECRET", "")}
    )

    case env("PUBLIC_BASE_URL", nil) do
      url when is_binary(url) and url != "" -> :persistent_term.put({:taskweft_deploy, :base_url}, url)
      _ -> :ok
    end

    port = String.to_integer(env("PORT", "8080"))
    Logger.info("taskweft MCP (OAuth/GitHub) listening on 0.0.0.0:#{port}")

    children = [
      {Plug.Cowboy,
       scheme: :http, plug: TaskweftDeploy.Router, options: [port: port, ip: {0, 0, 0, 0}]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TaskweftDeploy.Supervisor)
  end

  defp token_secret do
    case env("TASKWEFT_TOKEN_SECRET", nil) do
      s when is_binary(s) and byte_size(s) >= 16 ->
        s

      _ ->
        Logger.warning("TASKWEFT_TOKEN_SECRET unset/short — using an ephemeral dev key (tokens won't survive restart)")
        :crypto.strong_rand_bytes(32)
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      v -> v
    end
  end

  # "fire,@taskweft,org:V-Sekai-fire" -> %{logins: MapSet, orgs: MapSet}
  defp parse_allow(str) do
    {orgs, logins} =
      str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.split_with(&(String.starts_with?(&1, "@") or String.starts_with?(&1, "org:")))

    %{
      logins: MapSet.new(logins),
      orgs:
        orgs
        |> Enum.map(fn o -> o |> String.trim_leading("@") |> String.trim_leading("org:") end)
        |> MapSet.new()
    }
  end
end
