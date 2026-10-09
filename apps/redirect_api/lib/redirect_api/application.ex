defmodule RedirectApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([RedirectApi.Endpoint],
      strategy: :one_for_one,
      name: RedirectApi.Supervisor
    )
  end
end
