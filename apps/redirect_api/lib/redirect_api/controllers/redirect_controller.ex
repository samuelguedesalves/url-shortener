defmodule RedirectApi.RedirectController do
  use Phoenix.Controller, formats: [:json]

  alias RedirectApi.Resolver

  # ADR 0006: 302 with no-store so every click reaches this service (and is counted, ADR 0005)
  # and an expired link stops working immediately. The same header goes on 404, 410 and 503.
  def show(conn, %{"code" => code}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Resolver.resolve(code) do
      {:redirect, url} ->
        conn |> put_resp_header("location", url) |> send_resp(302, "")

      :gone ->
        conn |> put_status(:gone) |> json(%{error: "gone"})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      :unavailable ->
        conn |> put_status(:service_unavailable) |> json(%{error: "unavailable"})
    end
  end
end
