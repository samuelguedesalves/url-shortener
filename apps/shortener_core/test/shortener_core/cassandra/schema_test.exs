defmodule ShortenerCore.Cassandra.SchemaTest do
  use ExUnit.Case, async: true

  alias ShortenerCore.Cassandra.Schema

  test "returns the keyspace and table statements for valid input" do
    assert [keyspace_cql, table_cql] = Schema.statements("shortener", 3)
    assert keyspace_cql =~ "CREATE KEYSPACE IF NOT EXISTS shortener"
    assert keyspace_cql =~ "'replication_factor': 3"
    assert table_cql =~ "CREATE TABLE IF NOT EXISTS shortener.urls"
  end

  for keyspace <- ["bad-name", "Bad", "a; DROP", ""] do
    test "raises ArgumentError for the keyspace #{inspect(keyspace)}" do
      assert_raise ArgumentError, fn -> Schema.statements(unquote(keyspace), 1) end
    end
  end

  for replication_factor <- [0, -1, "3", nil] do
    test "raises ArgumentError for the replication factor #{inspect(replication_factor)}" do
      assert_raise ArgumentError, fn ->
        Schema.statements("shortener", unquote(replication_factor))
      end
    end
  end
end
