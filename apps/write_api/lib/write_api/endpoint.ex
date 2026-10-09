defmodule WriteApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :write_api

  plug Plug.RequestId
  plug Plug.Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 16_384

  plug WriteApi.Router
end
