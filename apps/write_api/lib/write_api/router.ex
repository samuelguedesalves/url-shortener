defmodule WriteApi.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  # Sets `conn.assigns.current_user` (or nil). Routes that need a signed-in user add
  # `WriteApi.Plugs.RequireUser` themselves.
  pipeline :session do
    plug WriteApi.Plugs.FetchUser
  end

  pipeline :authenticated do
    plug WriteApi.Plugs.RequireUser
  end

  # The dashboard pages. The Plug session here is LiveView's CSRF cookie only; who is signed in
  # comes from the `session` cookie, through `WriteApi.Dashboard.Auth`.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :live_csrf_session
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WriteApi.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  get "/health", WriteApi.HealthController, :show

  post "/auth/google", WriteApi.AuthController, :google
  post "/auth/logout", WriteApi.AuthController, :logout

  # Anonymous creation is allowed; a valid session only attaches the link to its owner.
  scope "/" do
    pipe_through :session

    post "/urls", WriteApi.UrlController, :create
  end

  scope "/" do
    pipe_through [:session, :authenticated]

    get "/me", WriteApi.MeController, :show
    get "/urls", WriteApi.UrlController, :index
  end

  scope "/" do
    pipe_through :browser

    live_session :dashboard,
      on_mount: {WriteApi.Dashboard.Auth, :fetch_user},
      session: {WriteApi.Dashboard.Auth, :live_session, []} do
      live "/dashboard", WriteApi.DashboardLive
    end
  end

  # Options are read per request so the cookie's `Secure` flag follows `:cookie_secure`.
  defp live_csrf_session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(WriteApi.Endpoint.live_csrf_options()))
  end
end
