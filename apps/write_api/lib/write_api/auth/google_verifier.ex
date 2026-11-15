defmodule WriteApi.Auth.GoogleVerifier do
  @moduledoc """
  Verifies a Google ID token: an RS256 signature by a key from Google's JWKS
  (`WriteApi.Auth.Jwks`), `iss` from Google, `aud` equal to `config :write_api,
  :google_client_id`, an unexpired `exp`, a verified email, and `sub` and `email` present.

  Only RS256 is accepted, so `alg: none` and HMAC tokens fail. With no client id configured
  every token fails closed with `:invalid_token`.
  """

  @behaviour WriteApi.Auth.Verifier

  alias WriteApi.Auth.Jwks

  @issuers ["accounts.google.com", "https://accounts.google.com"]
  @allowed_algs ["RS256"]

  @impl true
  def verify(credential), do: verify(credential, System.system_time(:second))

  @spec verify(term(), integer()) :: {:ok, map()} | {:error, :invalid_token | :unavailable}
  def verify(credential, now) when is_binary(credential) do
    with {:ok, client_id} <- client_id(),
         {:ok, kid} <- peek_kid(credential),
         {:ok, key} <- fetch_key(kid),
         {:ok, claims} <- check_signature(key, credential),
         :ok <- check_claims(claims, client_id, now) do
      {:ok, claims}
    end
  end

  def verify(_credential, _now), do: {:error, :invalid_token}

  defp client_id do
    case Application.get_env(:write_api, :google_client_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_token}
    end
  end

  defp peek_kid(credential) do
    case JOSE.JWS.peek_protected(credential) |> Jason.decode() do
      {:ok, %{"alg" => alg, "kid" => kid}} when alg in @allowed_algs and is_binary(kid) ->
        {:ok, kid}

      _ ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp fetch_key(kid) do
    case Jwks.get_key(kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_token}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp check_signature(key, credential) do
    case JOSE.JWT.verify_strict(key, @allowed_algs, credential) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp check_claims(claims, client_id, now) do
    valid? =
      claims["iss"] in @issuers and
        audience?(claims["aud"], client_id) and
        is_integer(claims["exp"]) and claims["exp"] > now and
        claims["email_verified"] in [true, "true"] and
        present?(claims["sub"]) and present?(claims["email"])

    if valid?, do: :ok, else: {:error, :invalid_token}
  end

  defp audience?(aud, client_id) when is_binary(aud), do: aud == client_id
  defp audience?(aud, client_id) when is_list(aud), do: client_id in aud
  defp audience?(_aud, _client_id), do: false

  defp present?(value), do: is_binary(value) and value != ""
end
