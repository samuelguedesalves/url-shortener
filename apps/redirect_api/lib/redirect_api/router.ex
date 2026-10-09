defmodule RedirectApi.Router do
  use Phoenix.Router

  get "/health", RedirectApi.HealthController, :show
  get "/:code", RedirectApi.RedirectController, :show
end
