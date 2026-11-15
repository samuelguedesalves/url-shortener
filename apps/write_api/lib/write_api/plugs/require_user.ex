defmodule WriteApi.Plugs.RequireUser do
  @moduledoc "Halts with 401 unless `WriteApi.Plugs.FetchUser` found a signed-in user."

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_user: %ShortenerCore.User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: "unauthenticated"})
    |> halt()
  end
end
