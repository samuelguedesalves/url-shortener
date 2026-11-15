defmodule WriteApi.Dashboard.Auth do
  @moduledoc """
  Who is signed in to the dashboard LiveView, and which origins may open its websocket.

  The `session` cookie (`WriteApi.Session`) is the only session. `live_session/1` puts its value
  into the LiveView session encrypted, because LiveView only signs that session into the page's
  `data-phx-session` attribute, where any script could read it. `on_mount(:fetch_user, ...)`
  decrypts it and verifies the cookie again on both the HTTP render and the connected mount, then
  loads the user. No user id is ever carried in the LiveView session, so nothing there is trusted
  beyond the signed cookie itself.

  The socket keeps the cookie only sealed (`:sealed_session_token`, still encrypted); `unseal/1`
  decrypts it on demand. The raw cookie is never an assign, so a crash report, which prints the
  whole LiveView state, cannot write it to the log.
  """

  import Phoenix.Component, only: [assign: 3]

  alias ShortenerCore.UserStore
  alias WriteApi.{Config, Session}

  @token_salt "dashboard session token"

  @doc """
  The LiveView session for `conn`: the `session` cookie, unverified and encrypted with the
  endpoint's `secret_key_base`, or nil when there is no cookie.
  """
  @spec live_session(Plug.Conn.t()) :: %{String.t() => String.t() | nil}
  def live_session(conn) do
    encrypted =
      case Session.token(conn) do
        {:ok, token} -> Plug.Crypto.encrypt(secret_key_base(), @token_salt, token)
        :none -> nil
      end

    %{"session_token" => encrypted}
  end

  @doc """
  Assigns `:sealed_session_token`, `:current_user` (a `ShortenerCore.User` or nil) and
  `:auth_error`.

  `:sealed_session_token` is the encrypted value from the LiveView session when it names a user,
  else nil; read the cookie from it with `unseal/1`. It is never rendered.
  A value that does not decrypt, an invalid, expired or tampered token, or a user that no longer
  exists, mounts signed out.
  When the user store is unavailable the view mounts signed out with `auth_error: :unavailable`.
  """
  @spec on_mount(:fetch_user, map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:fetch_user, _params, session, socket) do
    sealed = session["session_token"]
    {user, error} = load_user(unseal(sealed))

    socket =
      socket
      |> assign(:sealed_session_token, if(user, do: sealed))
      |> assign(:current_user, user)
      |> assign(:auth_error, error)

    {:cont, socket}
  end

  defp load_user(token) when is_binary(token) do
    with {:ok, user_id} <- Session.verify_token(token, DateTime.utc_now()),
         {:ok, user} <- UserStore.get(user_id) do
      {user, nil}
    else
      {:error, :unavailable} -> {nil, :unavailable}
      _ -> {nil, nil}
    end
  end

  defp load_user(_token), do: {nil, nil}

  @doc """
  The raw `session` cookie inside a sealed token (from `live_session/1`), or nil when it does not
  decrypt or is older than the session TTL. The cookie itself is not verified here.
  Never keep the result in an assign.
  """
  @spec unseal(String.t() | nil) :: String.t() | nil
  def unseal(encrypted) when is_binary(encrypted) do
    case Plug.Crypto.decrypt(secret_key_base(), @token_salt, encrypted,
           max_age: Config.session_ttl()
         ) do
      {:ok, token} when is_binary(token) -> token
      _ -> nil
    end
  end

  def unseal(_encrypted), do: nil

  defp secret_key_base, do: WriteApi.Endpoint.config(:secret_key_base)

  @doc """
  The websocket `check_origin` callback: true only when `origin` is the configured
  `:dashboard_origin` (same scheme, host and port). False for every origin while none is set.
  """
  @spec check_origin?(URI.t()) :: boolean()
  def check_origin?(%URI{} = origin) do
    case Application.get_env(:write_api, :dashboard_origin) do
      allowed when is_binary(allowed) and allowed != "" ->
        same_origin?(origin, URI.parse(allowed))

      _ ->
        false
    end
  end

  defp same_origin?(%URI{host: host} = a, %URI{} = b) when is_binary(host) do
    down(a.scheme) == down(b.scheme) and down(host) == down(b.host) and a.port == b.port
  end

  defp same_origin?(_a, _b), do: false

  defp down(nil), do: nil
  defp down(value), do: String.downcase(value)
end
