defmodule WriteApi.Router do
  use Phoenix.Router

  get "/health", WriteApi.HealthController, :show
  post "/urls", WriteApi.UrlController, :create
end
