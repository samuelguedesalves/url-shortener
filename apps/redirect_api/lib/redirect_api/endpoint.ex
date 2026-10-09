defmodule RedirectApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :redirect_api

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Head

  plug RedirectApi.Router
end
