defmodule RedirectApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :redirect_api

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Head

  plug :no_store
  plug RedirectApi.Router

  # ADR 0006: every response, including unmatched routes and errors, carries no-store.
  def no_store(conn, _opts), do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")
end
