defmodule WriteApi.LinksTest do
  use ExUnit.Case, async: false

  alias ShortenerCore.{Url, UrlStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.DownStore
  alias WriteApi.Links

  setup do
    start_supervised!(UrlStore.Memory)
    :ok
  end

  # Cassandra keeps milliseconds, so the fixtures do too.
  defp seed(owner_id, count, opts \\ []) do
    base = DateTime.truncate(DateTime.utc_now(), :millisecond)

    for i <- 1..count do
      code = "#{owner_id}-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      created_at = DateTime.add(base, i, :second)

      :ok =
        UrlStore.claim(%Url{
          code: code,
          owner_id: owner_id,
          is_custom_alias: false,
          created_at: created_at,
          expires_at: DateTime.add(created_at, 3600, :second)
        })

      unless opts[:no_destination],
        do: UrlStore.put_destination(code, "https://example.com/" <> code, 3600)

      code
    end
  end

  test "pages through 25 links with limit 10 as 10/10/5 without duplicates" do
    seed("userA", 25)

    assert {:ok, %{links: p1, next_cursor: c1}} = Links.page("userA", %{"limit" => "10"})
    assert length(p1) == 10
    assert is_binary(c1)

    assert {:ok, %{links: p2, next_cursor: c2}} =
             Links.page("userA", %{"limit" => "10", "cursor" => c1})

    assert length(p2) == 10
    assert is_binary(c2)

    assert {:ok, %{links: p3, next_cursor: nil}} =
             Links.page("userA", %{"limit" => "10", "cursor" => c2})

    assert length(p3) == 5

    codes = Enum.map(p1 ++ p2 ++ p3, & &1.code)
    assert length(Enum.uniq(codes)) == 25
  end

  test "an exact multiple of the limit has no next cursor on the last page" do
    seed("userA", 4)
    assert {:ok, %{links: [_, _], next_cursor: c}} = Links.page("userA", %{"limit" => "2"})

    assert {:ok, %{links: [_, _], next_cursor: nil}} =
             Links.page("userA", %{"limit" => "2", "cursor" => c})
  end

  test "defaults the limit to 20" do
    seed("userA", 25)
    assert {:ok, %{links: links, next_cursor: c}} = Links.page("userA", %{})
    assert length(links) == 20
    assert is_binary(c)
  end

  test "returns link maps with the view keys" do
    [code] = seed("userA", 1)
    assert {:ok, %{links: [link], next_cursor: nil}} = Links.page("userA", %{})
    assert link.code == code
    assert link.status == "active"
    assert link.short_url == "http://localhost:4002/" <> code
  end

  test "a link without a destination is expired with no long_url" do
    [code] = seed("userA", 1, no_destination: true)
    assert {:ok, %{links: [link]}} = Links.page("userA", %{})
    assert link.code == code
    assert link.status == "expired"
    assert link.long_url == nil
  end

  test "an empty owner gets an empty page" do
    assert {:ok, %{links: [], next_cursor: nil}} = Links.page("nobody", %{})
  end

  test "rejects an invalid limit" do
    for limit <- ["0", "101", "abc", "1.5", "-1", "", " 5", "5\n"] do
      assert Links.page("userA", %{"limit" => limit}) == {:error, :invalid_limit}, limit
    end

    assert Links.page("userA", %{"limit" => ["1"]}) == {:error, :invalid_limit}
  end

  test "accepts the limit bounds" do
    assert {:ok, _} = Links.page("userA", %{"limit" => "1"})
    assert {:ok, _} = Links.page("userA", %{"limit" => "100"})
  end

  test "rejects an invalid cursor" do
    assert Links.page("userA", %{"cursor" => "garbage"}) == {:error, :invalid_cursor}
    assert Links.page("userA", %{"cursor" => ""}) == {:error, :invalid_cursor}
  end

  test "a cursor from user A never returns A's links to user B" do
    seed("userA", 5)
    [b_code] = seed("userB", 1)

    {:ok, %{next_cursor: cursor}} = Links.page("userA", %{"limit" => "2"})
    assert {:ok, %{links: links}} = Links.page("userB", %{"cursor" => cursor})

    refute Enum.any?(links, &String.starts_with?(&1.code, "userA"))
    assert Enum.all?(links, &(&1.code == b_code))
  end

  test "reports unavailable when the store is down" do
    Doubles.swap_env(:shortener_core, :url_store, DownStore)
    assert Links.page("userA", %{}) == {:error, :unavailable}
  end
end
