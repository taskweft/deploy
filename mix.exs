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
      {:taskweft, github: "taskweft/taskweft"},
      {:plug_cowboy, "~> 2.7"},
      {:req, "~> 0.6"},
      # Assent = the GitHub OAuth *client* leg (DB-free; the same lib pow_assent
      # wraps in v-sekai zone-backend). Access/code/state/client artifacts are
      # our own macaroons (TaskweftDeploy.Macaroon, :crypto only) — no Ecto/Pow/
      # Postgres and no token library; every artifact is stateless.
      {:assent, "~> 0.2.13"}
    ]
  end
end
