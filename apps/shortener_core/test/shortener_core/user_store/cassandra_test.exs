defmodule ShortenerCore.UserStore.CassandraTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration

  use ShortenerCore.UserStoreContract, store: ShortenerCore.UserStore.Cassandra

  setup_all do
    ShortenerCore.Cassandra.Schema.setup!()
    :ok
  end

  setup do
    start_supervised!(ShortenerCore.Cassandra)
    :ok
  end

  test "returns {:error, :unavailable} when Cassandra cannot be reached" do
    user = new_user()
    stop_supervised!(ShortenerCore.Cassandra)

    start_supervised!(
      {ShortenerCore.Cassandra, nodes: ["127.0.0.1:1"], keyspace: "system"},
      id: :unreachable
    )

    log =
      capture_log(fn ->
        assert ShortenerCore.UserStore.Cassandra.get(user.id) == {:error, :unavailable}

        assert ShortenerCore.UserStore.Cassandra.get_by_google_id(user.google_id) ==
                 {:error, :unavailable}

        assert ShortenerCore.UserStore.Cassandra.claim_google_id(user.google_id, user.id) ==
                 {:error, :unavailable}

        assert ShortenerCore.UserStore.Cassandra.put(user) == {:error, :unavailable}
      end)

    assert log =~ "get failed"
    assert log =~ "get_by_google_id failed"
    assert log =~ "claim_google_id failed"
    assert log =~ "put failed"
  end
end
