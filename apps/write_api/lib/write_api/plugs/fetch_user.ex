defmodule WriteApi.Plugs.FetchUser do
  @moduledoc """
  Sets `conn.assigns.current_user` to the signed-in `ShortenerCore.User`, or nil.

  No cookie, an invalid cookie, or a user that no longer exists all give nil. When the user
  store is unavailable the request halts with 503 rather than treating the caller as signed out.
  """

  @behaviour Plug

  import Plug.Conn

  alias ShortenerCore.UserStore
  alias WriteApi.Session

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Session.user_id(conn) do
      :none -> assign(conn, :current_user, nil)
      {:ok, user_id} -> load(conn, user_id)
    end
  end

  defp load(conn, user_id) do
    case UserStore.get(user_id) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :not_found ->
        assign(conn, :current_user, nil)

      {:error, :unavailable} ->
        conn
        |> put_status(503)
        |> Phoenix.Controller.json(%{error: "unavailable"})
        |> halt()
    end
  end
end
