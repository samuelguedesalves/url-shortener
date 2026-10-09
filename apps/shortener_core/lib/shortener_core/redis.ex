defmodule ShortenerCore.Redis do
  @moduledoc "The shared Redis connection."

  @conn __MODULE__

  def conn, do: @conn

  @doc "Child spec for the supervision tree. `opts` override the application config."
  def child_spec(opts \\ []) do
    url = Keyword.get(opts, :url, Application.fetch_env!(:shortener_core, :redis_url))

    %{id: @conn, start: {Redix, :start_link, [url, [name: @conn]]}}
  end
end
