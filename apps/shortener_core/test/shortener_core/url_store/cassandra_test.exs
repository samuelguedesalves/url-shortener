defmodule ShortenerCore.UrlStore.CassandraTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  use ShortenerCore.UrlStoreContract, store: ShortenerCore.UrlStore.Cassandra

  setup_all do
    ShortenerCore.Cassandra.Schema.setup!()
    :ok
  end

  setup do
    start_supervised!(ShortenerCore.Cassandra)
    :ok
  end

  test "returns {:error, :unavailable} when Cassandra cannot be reached" do
    url = new_url()
    stop_supervised!(ShortenerCore.Cassandra)

    start_supervised!(
      {ShortenerCore.Cassandra, nodes: ["127.0.0.1:1"], keyspace: "system"},
      id: :unreachable
    )

    assert ShortenerCore.UrlStore.Cassandra.claim(url) == {:error, :unavailable}
    assert ShortenerCore.UrlStore.Cassandra.fetch(url.code) == {:error, :unavailable}
  end
end
