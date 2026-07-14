# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftDeploy.Macaroon do
  @moduledoc """
  A minimal, self-owned macaroon — first-party caveats only (no third-party
  discharge). We own this rather than pull a stale hex dep because it is the
  security-critical token primitive.

  A macaroon is an `identifier` (public, integrity-protected) plus an ordered
  list of caveat predicates, authenticated by an HMAC-SHA256 chain:

      sig₀ = HMAC(root_key, identifier)
      sigᵢ = HMAC(sig_{i-1}, caveatᵢ)

  The final `sig` is the credential. Because each caveat extends the chain, a
  holder can **add** caveats to attenuate (restrict) a macaroon offline
  (`attenuate/2`) but cannot remove or alter existing ones without the root key.
  Verification recomputes the chain and then requires **every** caveat to be
  satisfied — unknown caveats fail closed, so attenuation only ever narrows
  authority.

  Wire form: URL-safe base64 of a small JSON envelope `{i, c, s}` (all fields
  themselves base64url), so a token is one opaque bearer string.
  """

  @enforce_keys [:identifier, :sig]
  defstruct identifier: nil, caveats: [], sig: nil

  @type t :: %__MODULE__{identifier: binary(), caveats: [binary()], sig: binary()}

  @doc "Mint a macaroon binding `identifier` and `caveats` under `root_key`."
  @spec mint(binary(), binary(), [binary()]) :: t()
  def mint(root_key, identifier, caveats \\ [])
      when is_binary(root_key) and is_binary(identifier) and is_list(caveats) do
    sig = Enum.reduce(caveats, hmac(root_key, identifier), fn c, s -> hmac(s, c) end)
    %__MODULE__{identifier: identifier, caveats: caveats, sig: sig}
  end

  @doc "Append a first-party caveat, restricting the macaroon (holder-side attenuation)."
  @spec attenuate(t(), binary()) :: t()
  def attenuate(%__MODULE__{} = m, caveat) when is_binary(caveat) do
    %{m | caveats: m.caveats ++ [caveat], sig: hmac(m.sig, caveat)}
  end

  @doc """
  Verify the HMAC chain under `root_key`, then require `verifier.(caveat)` to
  return true for every caveat. Returns `{:ok, identifier}` or `{:error, reason}`.
  """
  @spec verify(binary(), t(), (binary() -> boolean())) ::
          {:ok, binary()} | {:error, :bad_signature | :caveat_unsatisfied}
  def verify(root_key, %__MODULE__{} = m, verifier) when is_function(verifier, 1) do
    expected = Enum.reduce(m.caveats, hmac(root_key, m.identifier), fn c, s -> hmac(s, c) end)

    cond do
      not Plug.Crypto.secure_compare(expected, m.sig) -> {:error, :bad_signature}
      not Enum.all?(m.caveats, verifier) -> {:error, :caveat_unsatisfied}
      true -> {:ok, m.identifier}
    end
  end

  @doc "Serialize to a single opaque URL-safe bearer string."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = m) do
    %{
      "i" => b64(m.identifier),
      "c" => Enum.map(m.caveats, &b64/1),
      "s" => b64(m.sig)
    }
    |> Jason.encode!()
    |> b64()
  end

  @doc "Parse a bearer string back into a macaroon."
  @spec decode(String.t()) :: {:ok, t()} | :error
  def decode(token) when is_binary(token) do
    with {:ok, json} <- unb64(token),
         {:ok, %{"i" => i, "c" => c, "s" => s}} <- Jason.decode(json),
         {:ok, identifier} <- unb64(i),
         {:ok, sig} <- unb64(s),
         {:ok, caveats} <- decode_caveats(c) do
      {:ok, %__MODULE__{identifier: identifier, caveats: caveats, sig: sig}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp decode_caveats(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn c, {:ok, acc} ->
      case unb64(c) do
        {:ok, bin} -> {:cont, {:ok, [bin | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp decode_caveats(_), do: :error

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(str) when is_binary(str), do: Base.url_decode64(str, padding: false)
  defp unb64(_), do: :error
end
