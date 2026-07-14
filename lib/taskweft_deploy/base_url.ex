# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.BaseURL do
  @moduledoc """
  The public base URL for a request — shared by `Router` (OAuth endpoints,
  issuer) and `LandingPlug` (the MCP connection URL shown on the landing page).

  Prefers `PUBLIC_BASE_URL` (a stable issuer); otherwise derives from the Fly
  edge's forwarded headers (TLS terminates there, so the scheme is https).
  """

  import Plug.Conn

  @spec get(Plug.Conn.t()) :: String.t()
  def get(conn) do
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
