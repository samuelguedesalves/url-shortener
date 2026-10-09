defmodule WriteApi.UrlController do
  use Phoenix.Controller, formats: [:json]

  alias WriteApi.Shortener

  # Only the request body is read; query-string parameters are ignored.
  def create(conn, _params) do
    case Shortener.create(conn.body_params) do
      {:ok, link} ->
        conn |> put_status(:created) |> json(link)

      {:error, :alias_taken} ->
        error(conn, :conflict, "alias_taken")

      {:error, reason} when reason in [:invalid_url, :invalid_alias, :invalid_ttl] ->
        error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, :unavailable} ->
        error(conn, :service_unavailable, "unavailable")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
