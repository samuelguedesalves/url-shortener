defmodule WriteApi.Layouts do
  @moduledoc """
  The dashboard's root HTML layout. The stylesheet and script are served by the app itself
  (`Plug.Static` under `/assets`); light and dark follow the system preference.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: WriteApi.Endpoint,
    router: WriteApi.Router,
    statics: ~w(assets)

  @doc "The root layout. `csrf-token` is LiveView's own CSRF token, not the session."
  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <.live_title default="Meus links">{assigns[:page_title]}</.live_title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="min-h-screen bg-base-200">
        {@inner_content}
      </body>
    </html>
    """
  end
end
