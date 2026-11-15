defmodule WriteApi.Session do
  @moduledoc """
  The session cookie: a `Phoenix.Token` carrying the user id and the time it was issued,
  signed with `:session_secret`. Signed, not encrypted, so the id is readable by the client;
  it cannot be forged or extended.

  Expiry is checked here against `:session_ttl` (and the cookie's `max-age`), not by
  `Phoenix.Token`, so the clock can be passed in. Anything that is missing, malformed,
  tampered with, expired or signed with another secret reads as `:none`.
  """

  import Plug.Conn

  alias WriteApi.Config

  @cookie "session"
  @salt "write_api session"

  @doc "Sets the session cookie for `user_id`. `opts[:now]` is the issue time (a `DateTime`)."
  @spec issue(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def issue(conn, user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    token = Phoenix.Token.sign(secret!(), @salt, {user_id, DateTime.to_unix(now)})

    put_resp_cookie(conn, @cookie, token, cookie_opts() ++ [max_age: Config.session_ttl()])
  end

  @doc "Expires the session cookie."
  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn), do: delete_resp_cookie(conn, @cookie, cookie_opts())

  @doc "The user id in the request's session cookie, if it is valid at `now`."
  @spec user_id(Plug.Conn.t(), DateTime.t()) :: {:ok, String.t()} | :none
  def user_id(conn, now \\ DateTime.utc_now()) do
    with {:ok, token} <- token(conn), do: verify_token(token, now)
  end

  @doc "The raw session cookie value of the request, unverified."
  @spec token(Plug.Conn.t()) :: {:ok, String.t()} | :none
  def token(conn) do
    case fetch_cookies(conn).req_cookies[@cookie] do
      token when is_binary(token) -> {:ok, token}
      _ -> :none
    end
  end

  @doc "The user id in a session `token`, if it is valid at `now`."
  @spec verify_token(String.t(), DateTime.t()) :: {:ok, String.t()} | :none
  def verify_token(token, now) when is_binary(token) do
    with secret when is_binary(secret) <- Config.session_secret(),
         {:ok, {user_id, issued_at}} when is_binary(user_id) and is_integer(issued_at) <-
           Phoenix.Token.verify(secret, @salt, token, max_age: :infinity),
         true <- live?(issued_at, DateTime.to_unix(now)) do
      {:ok, user_id}
    else
      _ -> :none
    end
  end

  defp live?(issued_at, now), do: issued_at <= now and now - issued_at < Config.session_ttl()

  defp cookie_opts do
    [http_only: true, same_site: "Lax", path: "/", secure: Config.cookie_secure?()]
  end

  defp secret! do
    Config.session_secret() ||
      raise "no :session_secret configured; set SESSION_SECRET to sign session cookies"
  end
end
