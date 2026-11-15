defmodule WriteApi.UrlController do
  use Phoenix.Controller, formats: [:json]

  alias WriteApi.{Links, Shortener}

  # The reply keeps the documented four fields; `created_at` is for in-process callers.
  # Only the request body is read; query-string parameters are ignored. Behind `FetchUser`
  # only: a signed-in caller owns the link, anyone else creates an anonymous one.
  def create(conn, _params) do
    case Shortener.create(conn.body_params, owner_id: owner_id(conn)) do
      {:ok, link} ->
        conn |> put_status(:created) |> json(Map.delete(link, :created_at))

      {:error, :alias_taken} ->
        error(conn, :conflict, "alias_taken")

      {:error, reason} when reason in [:invalid_url, :invalid_alias, :invalid_ttl] ->
        error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, :unavailable} ->
        error(conn, :service_unavailable, "unavailable")
    end
  end

  # The signed-in user's links, newest first. Behind `RequireUser`, so `current_user` is set.
  def index(conn, _params) do
    case Links.page(conn.assigns.current_user.id, conn.query_params) do
      {:ok, page} ->
        json(conn, page)

      {:error, reason} when reason in [:invalid_limit, :invalid_cursor] ->
        error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, :unavailable} ->
        error(conn, :service_unavailable, "unavailable")
    end
  end

  defp owner_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp owner_id(_conn), do: nil

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
