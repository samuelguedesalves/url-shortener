defmodule WriteApi.Config do
  @moduledoc """
  Reads the session settings (config `:write_api`) and checks the secrets at boot.

  `runtime.exs` runs in every service, so it only reads the environment with safe defaults;
  the check that a production write_api has a session secret lives here, called from
  `WriteApi.Application.start/2`. It is enforced when `:require_secrets` is true, which only
  `config/prod.exs` sets.
  """

  @min_secret_bytes 32
  @min_secret_key_base_bytes 64

  @doc "The key session cookies are signed with, or nil when none is configured."
  @spec session_secret() :: String.t() | nil
  def session_secret, do: Application.get_env(:write_api, :session_secret)

  @doc "Seconds a session cookie stays valid."
  @spec session_ttl() :: pos_integer()
  def session_ttl, do: Application.get_env(:write_api, :session_ttl, 604_800)

  @doc "The Google OAuth client id, or nil when unset or blank."
  @spec google_client_id() :: String.t() | nil
  def google_client_id do
    case Application.get_env(:write_api, :google_client_id) do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc "Whether the session cookie carries the `Secure` attribute."
  @spec cookie_secure?() :: boolean()
  def cookie_secure?, do: Application.get_env(:write_api, :cookie_secure, true) != false

  @doc """
  Raises when secrets are required and `:session_secret` is missing or too short, or the
  endpoint's `:secret_key_base` is not a binary of at least #{@min_secret_key_base_bytes} bytes.
  """
  @spec validate!() :: :ok
  def validate! do
    if Application.get_env(:write_api, :require_secrets, false) do
      validate_session_secret!()
      validate_secret_key_base!()
    end

    :ok
  end

  defp validate_session_secret! do
    case session_secret() do
      secret when is_binary(secret) and byte_size(secret) >= @min_secret_bytes ->
        :ok

      _ ->
        raise "SESSION_SECRET must be set to at least #{@min_secret_bytes} bytes " <>
                "(for example `openssl rand -base64 48`)"
    end
  end

  defp validate_secret_key_base! do
    endpoint_env = Application.get_env(:write_api, WriteApi.Endpoint, [])

    case Keyword.get(endpoint_env, :secret_key_base) do
      key when is_binary(key) and byte_size(key) >= @min_secret_key_base_bytes ->
        :ok

      _ ->
        raise "SECRET_KEY_BASE must be set to at least #{@min_secret_key_base_bytes} bytes " <>
                "(for example `openssl rand -base64 64`)"
    end
  end
end
