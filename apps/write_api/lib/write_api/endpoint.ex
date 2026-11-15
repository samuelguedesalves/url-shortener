defmodule WriteApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :write_api

  # The dashboard LiveView's socket. Only the configured dashboard origin may open it, and the
  # connect checks LiveView's CSRF token (kept in its own cookie, see `live_csrf_options/0`).
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: {WriteApi.Dashboard.Auth, :check_origin?, []},
      connect_info: [session: {__MODULE__, :live_csrf_options, []}]
    ]

  # The built stylesheet and script (`mix assets.build`), served by the app itself.
  plug Plug.Static,
    at: "/",
    from: :write_api,
    gzip: not code_reloading?,
    only: ~w(assets)

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Logger

  # Before the body parser: a refused cross-origin POST must not be read.
  plug WriteApi.Plugs.Cors

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 16_384

  plug WriteApi.Router

  @doc """
  Options of the cookie that holds LiveView's CSRF token, and nothing else. Identity never comes
  from it: it is always the `session` cookie (`WriteApi.Session`), re-verified on mount.
  """
  @spec live_csrf_options() :: keyword()
  def live_csrf_options do
    [
      store: :cookie,
      key: "_write_api_csrf",
      signing_salt: "write_api live csrf",
      same_site: "Lax",
      http_only: true,
      secure: WriteApi.Config.cookie_secure?()
    ]
  end
end
