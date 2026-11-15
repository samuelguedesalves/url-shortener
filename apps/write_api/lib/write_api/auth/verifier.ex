defmodule WriteApi.Auth.Verifier do
  @moduledoc """
  Verifies a sign-in credential (a Google ID token) and returns its claims.

  `verify/1` calls the module in `config :write_api, :verifier`. The claims map has string
  keys as Google sends them (`sub`, `email`, `email_verified`, `name`, `picture`), ready for
  `ShortenerCore.Users.register_or_update/2`.
  """

  @callback verify(credential :: String.t()) ::
              {:ok, claims :: map()} | {:error, :invalid_token | :unavailable}

  @spec verify(String.t()) :: {:ok, map()} | {:error, :invalid_token | :unavailable}
  def verify(credential), do: impl().verify(credential)

  defp impl, do: Application.get_env(:write_api, :verifier, WriteApi.Auth.GoogleVerifier)
end
