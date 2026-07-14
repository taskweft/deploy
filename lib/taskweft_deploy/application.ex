# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Application do
  @moduledoc """
  Boots the hosted Taskweft MCP server: a Cowboy endpoint running
  `TaskweftDeploy.Router`, which gates every MCP request behind a GitHub
  identity whitelist and forwards the rest to `ExMCP.HttpPlug`.

  Config (runtime env):

    * `PORT` — listen port (default 8080; Fly maps 443/TLS → this).
    * `TASKWEFT_MCP_GH_ALLOW` — comma-separated whitelist. Bare entries are
      GitHub logins; `@name` or `org:name` entries are org memberships.
      Default `"fire"`.
  """

  use Application
  require Logger

  @auth_cache :taskweft_gh_auth_cache

  @impl true
  def start(_type, _args) do
    ensure_cache()
    :persistent_term.put({:taskweft_deploy, :auth}, parse_allow(allow_env()))

    port = String.to_integer(System.get_env("PORT", "8080"))

    Logger.info(
      "taskweft MCP listening on 0.0.0.0:#{port} — whitelist #{inspect(:persistent_term.get({:taskweft_deploy, :auth}))}"
    )

    children = [
      {Plug.Cowboy,
       scheme: :http, plug: TaskweftDeploy.Router, options: [port: port, ip: {0, 0, 0, 0}]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TaskweftDeploy.Supervisor)
  end

  defp ensure_cache do
    if :ets.whereis(@auth_cache) == :undefined do
      :ets.new(@auth_cache, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp allow_env, do: System.get_env("TASKWEFT_MCP_GH_ALLOW", "fire")

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
