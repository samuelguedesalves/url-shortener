defmodule WriteApi.ShortenerTest do
  use ExUnit.Case, async: false

  alias ShortenerCore.{Cache, UrlStore}
  alias WriteApi.Shortener

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    :ok
  end

  test "a generated link created with an owner_id is stored under that owner" do
    assert {:ok, %{code: code}} =
             Shortener.create(%{"url" => "https://example.com/a"}, owner_id: "user-1")

    assert {:ok, %{owner_id: "user-1", is_custom_alias: false}} = UrlStore.fetch(code)
  end

  test "a custom alias created with an owner_id is stored under that owner" do
    assert {:ok, %{code: "my-link"}} =
             Shortener.create(%{"url" => "https://example.com/a", "custom_alias" => "my-link"},
               owner_id: "user-1"
             )

    assert {:ok, %{owner_id: "user-1", is_custom_alias: true}} = UrlStore.fetch("my-link")
  end

  test "the owner's links are listed, and another owner's are not" do
    assert {:ok, %{code: mine}} =
             Shortener.create(%{"url" => "https://example.com/mine"}, owner_id: "user-1")

    assert {:ok, _} =
             Shortener.create(%{"url" => "https://example.com/theirs"}, owner_id: "user-2")

    assert {:ok, [%{code: ^mine, long_url: "https://example.com/mine"}]} =
             UrlStore.list_by_owner("user-1", 50)
  end

  test "without an owner_id the link has no owner" do
    assert {:ok, %{code: code}} = Shortener.create(%{"url" => "https://example.com/a"})
    assert {:ok, %{owner_id: nil}} = UrlStore.fetch(code)
  end

  test "the now option sets created_at and the expiry" do
    now = ~U[2026-11-09 13:00:00.000Z]

    assert {:ok, %{code: code, expires_at: expires_at}} =
             Shortener.create(%{"url" => "https://example.com/a", "ttl_seconds" => 3_600},
               now: now
             )

    assert expires_at == DateTime.add(now, 3_600, :second)
    assert {:ok, %{created_at: ^now}} = UrlStore.fetch(code)
  end

  test "invalid params are still rejected when an owner_id is given" do
    assert Shortener.create(%{"url" => "not a url"}, owner_id: "user-1") ==
             {:error, :invalid_url}

    assert UrlStore.list_by_owner("user-1", 50) == {:ok, []}
  end
end
