defmodule ShortenerCore.UrlStore.CassandraTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    log =
      capture_log(fn ->
        assert ShortenerCore.UrlStore.Cassandra.claim(url) == {:error, :unavailable}
        assert ShortenerCore.UrlStore.Cassandra.fetch(url.code) == {:error, :unavailable}
      end)

    assert log =~ "claim failed"
    assert log =~ "fetch failed"
  end

  test "a tiny cassandra_timeout never hangs: the call returns or maps to {:error, :unavailable}" do
    previous = Application.fetch_env!(:shortener_core, :cassandra_timeout)
    Application.put_env(:shortener_core, :cassandra_timeout, 1)
    on_exit(fn -> Application.put_env(:shortener_core, :cassandra_timeout, previous) end)

    url = new_url()

    capture_log(fn ->
      # Whether 1 ms is enough depends on the machine; either outcome is fine, a hang is not.
      assert ShortenerCore.UrlStore.Cassandra.claim(url) in [:ok, {:error, :unavailable}]

      result = ShortenerCore.UrlStore.Cassandra.fetch(url.code)

      assert match?({:ok, %ShortenerCore.Url{}}, result) or
               result in [:not_found, {:error, :unavailable}]
    end)
  end
end
