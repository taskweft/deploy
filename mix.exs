# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.MixProject do
  use Mix.Project

  def project do
    [
      app: :taskweft_deploy,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [taskweft_deploy: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      # :inets/:ssl are only pulled in for completeness; GitHub calls go through req.
      extra_applications: [:logger],
      mod: {TaskweftDeploy.Application, []}
    ]
  end

  defp deps do
    [
      # The entire taskweft featureset — planner NIF, MCP server, JSON-LD loader —
      # in one dep. Its OTP app starts nothing unless it is the Burrito binary.
      {:taskweft, "~> 0.4.0-dev"},
      # The generic OAuth-to-MCP bridge (macaroons, GitHub OAuth, MCP bearer
      # guard) — extracted from this repo (taskweft/deploy#9) since none of it
      # is actually Fly-specific.
      {:oauth_mcp_bridge, "~> 0.1.0-dev"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
