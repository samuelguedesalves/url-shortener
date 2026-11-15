defmodule WriteApi.MeController do
  use Phoenix.Controller, formats: [:json]

  alias WriteApi.UserView

  # `RequireUser` has already run, so `current_user` is a user.
  def show(conn, _params), do: json(conn, UserView.to_map(conn.assigns.current_user))
end
