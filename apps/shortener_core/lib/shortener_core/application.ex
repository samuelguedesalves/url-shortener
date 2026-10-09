defmodule ShortenerCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Tests swap in in-memory fakes and set start_clients: false.
    children =
      if Application.fetch_env!(:shortener_core, :start_clients) do
        [ShortenerCore.Cassandra, ShortenerCore.Redis]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: ShortenerCore.Supervisor)
  end
end
