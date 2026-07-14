# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Artifact do
  @moduledoc """
  Purpose-scoped OAuth artifacts, each a macaroon (`TaskweftDeploy.Macaroon`) —
  fully stateless, so nothing is lost across scale-to-zero restarts and there is
  no database or volume.

  The structured payload lives in the (integrity-protected) macaroon identifier;
  two caveats carry policy: `purpose=<p>` and `exp=<unix>`. A holder may attenuate
  by appending a tighter `exp=` caveat (the soonest bound wins, since every caveat
  must hold). Any caveat the verifier doesn't recognize fails closed, so
  attenuation can only ever narrow authority.

    * `:client`  — dynamic-registration client_id → `%{"uris" => [...], "name" => ...}`
    * `:state`   — GitHub-leg context → client_id, redirect_uri, PKCE, client state
    * `:code`    — our authorization code → client + PKCE + resolved login
    * `:access`  — the MCP bearer token → `%{"sub" => login}`
    * `:refresh` — long-lived renewal credential → `%{"sub" => login}`; lets a
      client silently mint a new `:access` token without a GitHub round-trip
      (OAuth 2.1 practice: short access-token TTL + refresh token, rather than
      one long-lived access token). Being stateless, a refresh isn't re-checked
      against the whitelist/org membership — it trusts the `sub` the original
      code exchange already verified — so tightening the whitelist doesn't
      revoke an outstanding refresh token before its own `exp`.

  The root key is read at runtime from `:persistent_term`
  (`TaskweftDeploy.Application`, from `TASKWEFT_TOKEN_SECRET`).
  """

  alias TaskweftDeploy.Macaroon

  @ttl %{
    client: 90 * 24 * 3600,
    state: 600,
    code: 60,
    access: 3600,
    refresh: 180 * 24 * 3600
  }

  @doc "Mint a bearer string for `purpose` carrying `payload`."
  @spec mint(atom(), map()) :: String.t()
  def mint(purpose, payload) when is_map_key(@ttl, purpose) and is_map(payload) do
    now = System.system_time(:second)
    caveats = ["purpose=#{purpose}", "exp=#{now + Map.fetch!(@ttl, purpose)}"]

    root_key()
    |> Macaroon.mint(Jason.encode!(payload), caveats)
    |> Macaroon.encode()
  end

  @doc "Verify signature + purpose + expiry; return the payload map."
  @spec verify(atom(), String.t()) :: {:ok, map()} | :error
  def verify(purpose, token) do
    now = System.system_time(:second)

    with {:ok, m} <- Macaroon.decode(token),
         {:ok, id} <- Macaroon.verify(root_key(), m, &satisfies?(&1, purpose, now)),
         {:ok, payload} when is_map(payload) <- Jason.decode(id) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  @doc "Access-token lifetime (seconds) for the `expires_in` field."
  def access_ttl, do: Map.fetch!(@ttl, :access)

  defp satisfies?("purpose=" <> p, purpose, _now), do: p == Atom.to_string(purpose)

  defp satisfies?("exp=" <> ts, _purpose, now) do
    match?({n, ""} when n > now, Integer.parse(ts))
  end

  # Unknown caveat (e.g. a holder attenuation we can't evaluate) → fail closed.
  defp satisfies?(_caveat, _purpose, _now), do: false

  defp root_key, do: :persistent_term.get({:taskweft_deploy, :token_secret})
end
