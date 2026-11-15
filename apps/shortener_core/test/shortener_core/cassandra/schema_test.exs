defmodule ShortenerCore.Cassandra.SchemaTest do
  use ExUnit.Case, async: true

  alias ShortenerCore.Cassandra.Schema

  test "returns the keyspace and table statements for valid input" do
    assert [keyspace_cql, urls_cql, urls_by_user_cql, users_cql, users_by_google_id_cql] =
             Schema.statements("shortener", 3)

    assert keyspace_cql =~ "CREATE KEYSPACE IF NOT EXISTS shortener"
    assert keyspace_cql =~ "'replication_factor': 3"
    assert urls_cql =~ "CREATE TABLE IF NOT EXISTS shortener.urls ("
    assert urls_by_user_cql =~ "CREATE TABLE IF NOT EXISTS shortener.urls_by_user"
    assert users_cql =~ "CREATE TABLE IF NOT EXISTS shortener.users ("
    assert users_by_google_id_cql =~ "CREATE TABLE IF NOT EXISTS shortener.users_by_google_id"
  end

  test "users is keyed by the internal id and holds the profile columns" do
    users_cql = Schema.statements("shortener", 1) |> Enum.find(&(&1 =~ "shortener.users ("))

    for column <- [
          "id uuid PRIMARY KEY",
          "google_id text",
          "email text",
          "name text",
          "picture_url text",
          "email_verified boolean",
          "created_at timestamp",
          "updated_at timestamp"
        ] do
      assert users_cql =~ column
    end
  end

  test "urls_by_user lists an owner's links newest first" do
    cql = Schema.statements("shortener", 1) |> Enum.find(&(&1 =~ "urls_by_user"))

    assert cql =~ "owner_id text"
    assert cql =~ "created_at timestamp"
    assert cql =~ "code text"
    assert cql =~ "PRIMARY KEY ((owner_id), created_at, code)"
    assert cql =~ "CLUSTERING ORDER BY (created_at DESC, code ASC)"
  end

  test "users_by_google_id is keyed by the Google sub and points at the internal id" do
    cql = Schema.statements("shortener", 1) |> Enum.find(&(&1 =~ "users_by_google_id"))

    assert cql =~ "google_id text PRIMARY KEY"
    assert cql =~ "user_id uuid"
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
