defmodule WriteApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([WriteApi.Endpoint], strategy: :one_for_one, name: WriteApi.Supervisor)
  end
end
