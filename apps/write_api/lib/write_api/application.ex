defmodule WriteApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    WriteApi.Config.validate!()

    children = [WriteApi.Auth.Jwks, WriteApi.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: WriteApi.Supervisor)
  end
end
